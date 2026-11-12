<?php

namespace Tests\Feature;

use Tests\TestCase;

/** Legacy HMAC links fail closed. Stateful security runs on dedicated MySQL. */
class Rc1NavigatorLinkSignatureTest extends TestCase
{
    private function reject(string $query): void
    {
        $controller = new \Fleetbase\FleetOps\Http\Controllers\Internal\v1\NavigatorController();
        $response = $controller->linkApp(\Illuminate\Http\Request::create('/navigator/link-app' . $query));
        self::assertSame(403, $response->getStatusCode());
    }

    public function test_missing_token_is_rejected(): void
    {
        $this->reject('');
    }

    public function test_legacy_expiry_and_signature_are_rejected(): void
    {
        $this->reject('?expires=' . (time() + 60) . '&signature=' . str_repeat('0', 64));
    }

    public function test_old_hmac_validator_is_not_available(): void
    {
        self::assertFalse(method_exists(\Fleetbase\FleetOps\Http\Controllers\Internal\v1\NavigatorController::class, 'hasValidLinkSignature'));
        self::assertFalse(method_exists(\Fleetbase\FleetOps\Http\Controllers\Internal\v1\NavigatorController::class, 'linkSignature'));
    }

    public function test_array_token_is_rejected(): void
    {
        $this->reject('?token[]=value');
    }

    public function test_anonymous_issuance_is_rejected(): void
    {
        $response = (new \Fleetbase\FleetOps\Http\Controllers\Internal\v1\NavigatorController())->getLinkAppUrl();
        self::assertSame(403, $response->getStatusCode());
    }
}
