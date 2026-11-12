<?php

namespace Tests\Unit;

use Kreait\Firebase\Factory;
use ReflectionMethod;
use Tests\TestCase;

/**
 * Non-networked Firebase QA checks: no credential material or message send.
 */
class Rc1FirebaseQaProjectTest extends TestCase
{
    public function test_explicit_project_id_resolves_in_installed_firebase_sdk(): void
    {
        $factory = (new Factory())->withProjectId('gsent-it');
        $method = new ReflectionMethod($factory, 'getProjectId');
        $method->setAccessible(true);

        $this->assertSame('gsent-it', $method->invoke($factory));
    }

    public function test_qa_overlay_requires_readonly_secret_mount_and_both_processes(): void
    {
        $path = dirname(__DIR__, 3) . '/deploy/compose.firebase.qa.yml';
        $this->assertFileExists($path);
        $yaml = file_get_contents($path);
        $this->assertIsString($yaml);
        $this->assertStringContainsString('GOOGLE_CLOUD_PROJECT: gsent-it', $yaml);
        $this->assertStringContainsString('FIREBASE_CREDENTIALS: /run/secrets/gst-firebase-qa.json', $yaml);
        $this->assertStringContainsString('GOOGLE_APPLICATION_CREDENTIALS: /run/secrets/gst-firebase-qa.json', $yaml);
        $this->assertSame(2, substr_count($yaml, 'read_only: true'));
        $this->assertStringContainsString('  application:', $yaml);
        $this->assertStringContainsString('  queue:', $yaml);
    }

    public function test_qa_overlay_never_embeds_private_credentials(): void
    {
        $yaml = file_get_contents(dirname(__DIR__, 3) . '/deploy/compose.firebase.qa.yml');
        $this->assertIsString($yaml);
        $this->assertStringNotContainsString('BEGIN PRIVATE KEY', $yaml);
        $this->assertStringNotContainsString('private_key_id:', $yaml);
        $this->assertStringNotContainsString('client_email:', $yaml);
    }
}
