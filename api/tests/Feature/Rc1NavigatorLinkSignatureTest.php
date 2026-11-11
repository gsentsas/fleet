<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Http\Controllers\Internal\v1\NavigatorController;
use Illuminate\Http\Request;
use ReflectionMethod;
use Tests\TestCase;

/**
 * S75: Exercises the real Navigator HMAC validator without invoking linkApp(),
 * provisioning credentials, creating tenants, or contacting external services.
 *
 * A valid link is currently a reusable bearer token: this suite intentionally
 * does NOT assert replay prevention or tenant/device binding, which are absent
 * from the current implementation and require an explicit release decision.
 */
class Rc1NavigatorLinkSignatureTest extends TestCase
{
    private const SYNTHETIC_TEST_APP_KEY = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

    protected function setUp(): void
    {
        parent::setUp();

        // Synthetic test-only key. Never read or expose runtime QA/prod keys.
        config(['app.key' => self::SYNTHETIC_TEST_APP_KEY]);
    }

    private function validatorAccepts(int|string|null $expires, ?string $signature): bool
    {
        $query = [];

        if ($expires !== null) {
            $query['expires'] = $expires;
        }

        if ($signature !== null) {
            $query['signature'] = $signature;
        }

        $method = new ReflectionMethod(NavigatorController::class, 'hasValidLinkSignature');

        return $method->invoke(
            (new \ReflectionClass(NavigatorController::class))->newInstanceWithoutConstructor(),
            Request::create('/int/v1/fleet-ops/navigator/link-app', 'GET', $query)
        );
    }

    public function test_missing_signature_or_expiry_is_rejected(): void
    {
        $this->assertFalse($this->validatorAccepts(null, null));
        $this->assertFalse($this->validatorAccepts(time() + 60, null));
        $this->assertFalse($this->validatorAccepts(time() + 60, ''));
        $this->assertFalse($this->validatorAccepts(null, str_repeat('0', 64)));
    }

    public function test_expired_link_is_rejected_with_real_controller_validator(): void
    {
        $expired = time() - 60;
        $signature = NavigatorController::linkSignature($expired);

        $this->assertFalse($this->validatorAccepts($expired, $signature));
    }

    public function test_forged_signature_is_rejected(): void
    {
        $expires = time() + 120;

        $this->assertFalse($this->validatorAccepts($expires, str_repeat('0', 64)));
        $this->assertFalse($this->validatorAccepts($expires, 'invalid-signature'));
    }

    public function test_expiry_tampering_invalidates_a_real_signed_link(): void
    {
        $expires = time() + 120;
        $signature = NavigatorController::linkSignature($expires);

        $this->assertFalse($this->validatorAccepts($expires + 60, $signature));
        $this->assertFalse($this->validatorAccepts($expires - 60, $signature));
    }

    public function test_valid_short_lived_signature_is_accepted_by_validator_only(): void
    {
        $expires = time() + 120;
        $signature = NavigatorController::linkSignature($expires);

        $this->assertSame(64, strlen($signature));
        $this->assertTrue($this->validatorAccepts($expires, $signature));
    }
}
