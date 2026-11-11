<?php

if (getenv('APP_ENV') !== 'testing' || getenv('DB_DATABASE') !== 'rc1_ci_schema'
    || !in_array(getenv('DB_HOST'), ['127.0.0.1', 'mysql'], true)) {
    fwrite(STDERR, "STOP=DISPOSABLE_SCHEMA_ENV_REQUIRED\n");
    exit(2);
}
$pdo = new PDO('mysql:host=' . getenv('DB_HOST'), getenv('DB_USERNAME'), getenv('DB_PASSWORD'), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
foreach (['rc1_ci_schema', 'rc1_ci_schema_storefront', 'rc1_ci_schema_sandbox'] as $database) {
    // Deliberately fail if a previous run left the schema: never silently reuse it.
    $pdo->exec('CREATE DATABASE ' . $database . ' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
}
echo "S48_FRESH_DISPOSABLE_SCHEMA=PASS\n";
