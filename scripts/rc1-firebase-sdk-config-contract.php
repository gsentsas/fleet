<?php
// S42: run from api/ with environment-only QA placeholders. Never read key files.
declare(strict_types=1);
require getcwd() . '/vendor/autoload.php';
$expected = '/run/secrets/gst-firebase-qa.json';
if (getenv('GOOGLE_CLOUD_PROJECT') !== 'gsent-it') {
    fwrite(STDERR, "STOP=FIREBASE_PROJECT_ENV_DRIFT\n");
    exit(2);
}
$config = require getcwd() . '/vendor/kreait/laravel-firebase/config/firebase.php';
$resolved = $config['projects']['app']['credentials'] ?? null;
if ($resolved !== $expected) {
    fwrite(STDERR, "STOP=FIREBASE_LARAVEL_CREDENTIAL_PATH_DRIFT\n");
    exit(2);
}
if (is_file(getcwd() . '/bootstrap/cache/config.php')) {
    fwrite(STDERR, "STOP=PRECOMPILED_LARAVEL_CONFIG_CACHE_PRESENT\n");
    exit(2);
}
echo "S42_FIREBASE_PROJECT_ID=PASS\n";
echo "S42_FIREBASE_LARAVEL_CONFIG_CREDENTIAL_PATH=PASS\n";
echo "S42_LARAVEL_CONFIG_CACHE_ABSENT=PASS\n";
echo "S42_REAL_PRIVATE_KEYS_USED=NO\n";
echo "S42_FCM_NETWORK_OR_SEND=NONE\n";
