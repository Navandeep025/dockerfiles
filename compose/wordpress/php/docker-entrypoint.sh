#!/bin/bash
set -e

# check that project name is defined
if [ -z "$PROJECT_NAME" ]; then
    echo >&2 "Error: missing PROJECT_NAME. You have to set up this variable in docker-compose.yml"
    exit 1
fi

#True if the length of "STRING" is non-zero.
if [ -n "$MYSQL_PORT_3306_TCP" ]; then
    #True of the length if "STRING" is zero.
	if [ -z "$WORDPRESS_DB_HOST" ]; then
		WORDPRESS_DB_HOST='mysql'
	else
		echo >&2 'warning: both WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP found'
		echo >&2 "  Connecting to WORDPRESS_DB_HOST ($WORDPRESS_DB_HOST)"
		echo >&2 '  instead of the linked mysql container'
	fi
fi

if [ -z "$WORDPRESS_DB_HOST" ]; then
	echo >&2 'error: missing WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP environment variables'
	echo >&2 '  Did you forget to --link some_mysql_container:mysql or set an external db'
	echo >&2 '  with -e WORDPRESS_DB_HOST=hostname:port?'
	exit 1
fi

# if we're linked to MySQL, and we're using the root user, and our linked
# container has a default "root" password set up and passed through... :)
: ${WORDPRESS_DB_USER:=root}
if [ "$WORDPRESS_DB_USER" = 'root' ]; then
	: ${WORDPRESS_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}
fi
: ${WORDPRESS_DB_NAME:=wordpress}

if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
	echo >&2 'error: missing required WORDPRESS_DB_PASSWORD environment variable'
	echo >&2 '  Did you forget to -e WORDPRESS_DB_PASSWORD=... ?'
	echo >&2
	echo >&2 '  (Also of interest might be WORDPRESS_DB_USER and WORDPRESS_DB_NAME.)'
	exit 1
fi

if ! [ -e $PROJECT_NAME/index.php -a -e $PROJECT_NAME/wp-includes/version.php ]; then
	echo >&2 "WordPress not found in $(pwd)/$PROJECT_NAME - copying now..."
	if [ "$(ls -A $PROJECT_NAME)" ]; then
		echo >&2 "WARNING: $(pwd)$PROJECT_NAME is not empty - press Ctrl+C now if this is an error!"
		( set -x; ls -A; sleep 10 )
	fi
	mkdir $PROJECT_NAME
	tar cf - --one-file-system -C /usr/src/wordpress . | tar xf - -C $PROJECT_NAME 
	echo >&2 "Complete! WordPress has been successfully copied to $(pwd)/$PROJECT_NAME"
	if [ ! -e $PROJECT_NAME/.htaccess ]; then
		# NOTE: The "Indexes" option is disabled in the php:apache base image
		cat > $PROJECT_NAME/.htaccess <<-'EOF'
			# BEGIN WordPress
			<IfModule mod_rewrite.c>
			RewriteEngine On
			RewriteBase /
			RewriteRule ^index\.php$ - [L]
			RewriteCond %{REQUEST_FILENAME} !-f
			RewriteCond %{REQUEST_FILENAME} !-d
			RewriteRule . /index.php [L]
			</IfModule>
			# END WordPress
		EOF
		chown www-data:www-data $PROJECT_NAME/.htaccess
	fi
fi

# TODO handle WordPress upgrades magically in the same way, but only if wp-includes/version.php's $wp_version is less than /usr/src/wordpress/wp-includes/version.php's $wp_version

if [ ! -e $PROJECT_NAME/wp-config.php ]; then
	awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' $PROJECT_NAME/wp-config-sample.php > $PROJECT_NAME/wp-config.php <<'EOPHP'
// If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
// see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
	$_SERVER['HTTPS'] = 'on';
}

EOPHP
	chown www-data:www-data $PROJECT_NAME/wp-config.php
fi

set_config() {
	key="$1"
	value="$2"
	php_escaped_value="$(php -r 'var_export($argv[1]);' "$value")"
	sed_escaped_value="$(echo "$php_escaped_value" | sed 's/[\/&]/\\&/g')"
	sed -ri "s/((['\"])$key\2\s*,\s*)(['\"]).*\3/\1$sed_escaped_value/" $PROJECT_NAME/wp-config.php
}

set_config 'DB_HOST' "$WORDPRESS_DB_HOST"
set_config 'DB_USER' "$WORDPRESS_DB_USER"
set_config 'DB_PASSWORD' "$WORDPRESS_DB_PASSWORD"
set_config 'DB_NAME' "$WORDPRESS_DB_NAME"

# allow any of these "Authentication Unique Keys and Salts." to be specified via
# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
UNIQUES=(
	AUTH_KEY
	SECURE_AUTH_KEY
	LOGGED_IN_KEY
	NONCE_KEY
	AUTH_SALT
	SECURE_AUTH_SALT
	LOGGED_IN_SALT
	NONCE_SALT
)
for unique in "${UNIQUES[@]}"; do
	eval unique_value=\$WORDPRESS_$unique
	if [ "$unique_value" ]; then
		set_config "$unique" "$unique_value"
	else
		# if not specified, let's generate a random value
		current_set="$(sed -rn "s/define\((([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\);/\4/p" $PROJECT_NAME/wp-config.php)"
		if [ "$current_set" = 'put your unique phrase here' ]; then
			set_config "$unique" "$(head -c1M /dev/urandom | sha1sum | cut -d' ' -f1)"
		fi
	fi
done

TERM=dumb php -- "$WORDPRESS_DB_HOST" "$WORDPRESS_DB_USER" "$WORDPRESS_DB_PASSWORD" "$WORDPRESS_DB_NAME" <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

$stderr = fopen('php://stderr', 'w');

list($host, $port) = explode(':', $argv[1], 2);

$maxTries = 10;
do {
	$mysql = new mysqli($host, $argv[2], $argv[3], '', (int)$port);
	if ($mysql->connect_error) {
		fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ($mysql->connect_error);

if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($argv[4]) . '`')) {
	fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}

//create pma database
if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `phpmyadmin`')) {
    fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
    $mysql->close();
    exit(1);
}

//add privileges to pma user
if (!$mysql->query("GRANT SELECT, INSERT, UPDATE, DELETE ON phpmyadmin.* TO 'pma'@'%'  IDENTIFIED BY 'pmapass'")) {
    fwrite($stderr, "\n" . 'MySQL "GRANT PRIVILEGES" Error: ' . $mysql->error . "\n");
    $mysql->close();
    exit(1);
}


//Execute a mysql file: http://php.net/manual/en/mysqli.multi-query.php
$commands = file_get_contents("/usr/src/phpmyadmin/sql/create_tables.sql");

if (!$mysql->multi_query($commands)) {
    fwrite($stderr, "\n" . 'MySQL "Create Tables" Error: ' . $mysql->error . "\n");
    $mysql->close();
    exit(1);
}


$mysql->close();
EOPHP

if ! [ -e /var/www/html/$PROJECT_NAME/phpmyadmin ]; then
    echo >&2 "phpMyAdmin not found in $(pwd)/$PROJECT_NAME - copying now..."
    cp -ra /usr/src/phpmyadmin /var/www/html/$PROJECT_NAME/
    echo >&2 "Complete! phpMyAdmin has been successfully copied to $(pwd)/$PROJECT_NAME"
fi

#Execute docker CMD
exec "$@"
