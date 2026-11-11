<?php

namespace Tests\Unit;

use Tests\TestCase;


class Rc1FirebaseQaSecretPreflightTest extends TestCase
{
    private function script(): string
    {
        $path = dirname(__DIR__, 3) . '/scripts/rc1-firebase-qa-secret-preflight.sh';
        $this->assertFileExists($path);
        return (string) file_get_contents($path);
    }

    public function test_missing_qa_key_is_an_explicit_hard_stop(): void
    {
        $script = $this->script();
        $this->assertStringContainsString('STOP=QA_FIREBASE_KEY_NOT_PROVISIONED', $script);
        $this->assertStringContainsString('STOP=SECRET_PERMISSIONS_TOO_BROAD', $script);
        $this->assertStringContainsString('STOP=SECRET_DIRECTORY_TOO_OPEN', $script);
        $this->assertStringContainsString('STOP=SECRET_SYMLINK_OR_INVALID', $script);
    }

    public function test_wrong_firebase_project_and_compose_scope_are_rejected(): void
    {
        $script = $this->script();
        $this->assertStringContainsString("data.get('project_id')!='gsent-it'", $script);
        $this->assertStringContainsString('STOP=QA_FIREBASE_IDENTITY_INVALID', $script);
        $this->assertStringContainsString('STOP=WRONG_COMPOSE_PROJECT', $script);
        $this->assertStringContainsString('STOP=SECRET_MOUNTS_NOT_READONLY', $script);
        $this->assertStringContainsString('STOP=SECRET_SOURCE_DRIFT', $script);
    }

    public function test_preflight_never_starts_or_mutates_containers(): void
    {
        $script = $this->script();
        $this->assertStringContainsString('S39_QA_CONTAINER_START=NOT_PERFORMED', $script);
        $this->assertStringNotContainsString('docker run ', $script);
        $this->assertStringNotContainsString('docker compose up', $script);
        $this->assertStringNotContainsString('docker volume rm', $script);
        $this->assertStringNotContainsString('docker stop ', $script);
    }
}
