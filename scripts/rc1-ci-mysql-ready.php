<?php

if (getenv('APP_ENV') !== 'testing' || !in_array(getenv('DB_HOST'), ['127.0.0.1', 'mysql'], true)) {
    fwrite(STDERR, "STOP=DISPOSABLE_MYSQL_ENV_REQUIRED\n");
    exit(2);
}
for ($attempt = 0; $attempt < 30; $attempt++) {
    try {
        $pdo = new PDO('mysql:host=' . getenv('DB_HOST') . ';dbname=' . getenv('DB_DATABASE'), getenv('DB_USERNAME'), getenv('DB_PASSWORD'), [PDO::ATTR_TIMEOUT => 2]);
        $pdo->query('SELECT 1');
        echo "RC1_EPHEMERAL_MYSQL_READY=PASS\n";
        exit(0);
    } catch (PDOException $exception) {
        sleep(2);
    }
}
fwrite(STDERR, "STOP=EPHEMERAL_MYSQL_NOT_READY\n");
exit(2);
