<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Support\NavigatorCredentialService;
use Fleetbase\FleetOps\Support\NavigatorLinkTokenService;
use Fleetbase\Models\ApiCredential;
use Fleetbase\Models\User;
use Fleetbase\Support\NavigatorCredentialScope;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use PHPUnit\Framework\Attributes\Group;
use Tests\TestCase;

/** Real locked Laravel app, registered routes/middleware/observers and disposable MySQL. */
#[Group('rc1-mysql-only')]
class Rc1NavigatorMySqlTest extends TestCase
{
    private User $adminA;
    private User $adminB;
    private NavigatorLinkTokenService $links;
    private NavigatorCredentialService $credentials;

    protected function setUp(): void
    {
        parent::setUp();
        self::assertSame('1', getenv('RC1_NAVIGATOR_MYSQL'));
        self::assertSame('testing', config('app.env'));
        self::assertSame('mysql', DB::connection()->getDriverName());
        self::assertSame('rc1_ci_schema', DB::connection()->getDatabaseName());
        session()->flush();
        foreach (['A', 'B'] as $label) {
            $company = (string) Str::uuid();
            $uuid = (string) Str::uuid();
            DB::table('companies')->insert(['uuid' => $company, 'public_id' => 'company_' . Str::random(16), 'name' => 'S92 ' . $label]);
            DB::table('users')->insert(['uuid' => $uuid, 'company_uuid' => $company, 'type' => 'admin', 'status' => 'active']);
            DB::table('companies')->where('uuid', $company)->update(['owner_uuid' => $uuid]);
            $this->{'admin' . $label} = User::findOrFail($uuid);
        }
        $this->links = new NavigatorLinkTokenService();
        $this->credentials = new NavigatorCredentialService();
    }

    private function pair(?User $issuer = null): ApiCredential
    {
        $token = $this->links->issue($issuer ?? $this->adminB);
        return $this->links->redeemWith($token, fn ($user) => $this->credentials->issue($user));
    }

    private function driver(User $admin): User
    {
        $uuid = (string) Str::uuid();
        DB::table('users')->insert([
            'uuid' => $uuid, 'company_uuid' => $admin->company_uuid, 'type' => 'driver', 'status' => 'active',
            'email' => Str::random(16) . '@example.test', 'password' => Hash::make('S92_test_password_only'),
        ]);
        DB::table('drivers')->insert([
            'uuid' => (string) Str::uuid(), 'public_id' => 'driver_' . Str::random(16),
            'company_uuid' => $admin->company_uuid, 'user_uuid' => $uuid,
            'location' => DB::raw('POINT(0, 0)'),
        ]);
        return User::findOrFail($uuid);
    }

    public function test_pairing_has_distinct_non_admin_identity_and_bounded_expiry(): void
    {
        $one = $this->pair();
        $two = $this->pair();
        self::assertNotSame($one->uuid, $two->uuid);
        self::assertNotSame($one->key, $two->key);
        self::assertSame($this->adminB->company_uuid, $one->company_uuid);
        self::assertSame($this->adminB->uuid, $one->issuer_user_uuid);
        self::assertNotSame($this->adminB->uuid, $one->user_uuid);
        self::assertSame('navigator-device', $one->user->type);
        self::assertFalse($one->user->isAdmin());
        self::assertFalse($one->user->canAccessConsole());
        self::assertFalse($one->user->canHoldConsoleSession());
        self::assertTrue($one->expires_at->lte(now()->addDays(7)));
        self::assertTrue(NavigatorCredentialScope::valid($one));
        self::assertSame($one->key, ApiCredential::withoutGlobalScopes()->findOrFail($one->uuid)->key);
    }

    public function test_hash_only_storage_and_replay_forgery_and_expiry_are_rejected(): void
    {
        $token = $this->links->issue($this->adminB);
        $row = DB::table('fleetops_navigator_link_tokens')->where('token_hash', hash('sha256', $token))->first();
        self::assertSame($this->adminB->uuid, $row->issuer_user_uuid);
        self::assertStringNotContainsString($token, json_encode($row));
        foreach (['short', strtoupper($token), str_repeat('0', 64)] as $invalid) {
            self::assertNull($this->links->redeem($invalid));
        }
        self::assertSame($this->adminB->uuid, $this->links->redeem($token)->uuid);
        self::assertNull($this->links->redeem($token));
        $token = $this->links->issue($this->adminB);
        DB::table('fleetops_navigator_link_tokens')->where('token_hash', hash('sha256', $token))->update(['expires_at' => now()]);
        self::assertNull($this->links->redeem($token));
    }

    public function test_inactive_issuer_cannot_issue_or_redeem(): void
    {
        $token = $this->links->issue($this->adminB);
        DB::table('users')->where('uuid', $this->adminB->uuid)->update(['status' => 'inactive']);
        self::assertNull($this->links->redeem($token));
        $this->expectException(\RuntimeException::class);
        $this->links->issue($this->adminB->fresh());
    }

    public function test_non_admin_issuer_is_denied(): void
    {
        $this->expectException(\RuntimeException::class);
        $this->links->issue($this->driver($this->adminB));
    }

    public function test_credential_failure_rolls_back_all_writes_and_link_can_be_retried(): void
    {
        $token = $this->links->issue($this->adminB);
        $before = DB::table('api_credentials')->count();
        $users = DB::table('users')->count();
        try {
            $this->links->redeemWith($token, function ($issuer) {
                $this->credentials->issue($issuer);
                throw new \RuntimeException('synthetic failure after credential persistence');
            });
            self::fail('Expected issuance failure');
        } catch (\RuntimeException $exception) {
            self::assertSame('synthetic failure after credential persistence', $exception->getMessage());
        }
        self::assertSame($before, DB::table('api_credentials')->count());
        self::assertSame($users, DB::table('users')->count());
        self::assertNull(DB::table('fleetops_navigator_link_tokens')->where('token_hash', hash('sha256', $token))->value('consumed_at'));
        self::assertInstanceOf(ApiCredential::class, $this->links->redeemWith($token, fn ($issuer) => $this->credentials->issue($issuer)));
        self::assertNull($this->links->redeem($token));
    }

    public function test_concurrent_redemption_creates_exactly_one_credential(): void
    {
        self::assertTrue(function_exists('pcntl_fork'));
        $token = $this->links->issue($this->adminB);
        $before = DB::table('api_credentials')->count();
        $gate = microtime(true) + 0.3;
        DB::disconnect();
        $children = [];
        for ($i = 0; $i < 2; $i++) {
            $pid = pcntl_fork();
            self::assertNotSame(-1, $pid);
            if ($pid === 0) {
                while (microtime(true) < $gate) { usleep(1000); }
                try {
                    DB::purge();
                    $result = $this->links->redeemWith($token, function ($issuer) {
                        usleep(100000);
                        return $this->credentials->issue($issuer);
                    });
                    exit($result instanceof ApiCredential ? 10 : 20);
                } catch (\Throwable $exception) {
                    // Do not print exception payloads or credentials from children.
                    exit(30);
                }
            }
            $children[] = $pid;
        }
        $outcomes = [];
        foreach ($children as $pid) {
            pcntl_waitpid($pid, $status);
            self::assertTrue(pcntl_wifexited($status));
            $outcomes[] = pcntl_wexitstatus($status);
        }
        sort($outcomes);
        self::assertSame([10, 20], $outcomes);
        DB::purge();
        self::assertSame($before + 1, DB::table('api_credentials')->count());
    }

    public function test_bootstrap_key_cannot_read_or_write_transport_or_create_accounts(): void
    {
        $key = $this->pair();
        $this->withToken($key->key)->getJson('/v1/orders')->assertForbidden();
        $this->withToken($key->key)->postJson('/v1/orders', [])->assertForbidden();
        $this->withToken($key->key)->postJson('/v1/drivers/verify-code', ['for' => 'create_driver'])->assertForbidden();
        $this->withToken($key->key)->getJson('/v1/drivers')->assertForbidden();
    }

    public function test_revoked_and_expired_keys_fail_even_for_options(): void
    {
        $key = $this->pair();
        DB::table('api_credentials')->where('uuid', $key->uuid)->update(['expires_at' => now()->subSecond()]);
        $this->withToken($key->key)->postJson('/v1/drivers/login', [])->assertUnauthorized();
        $key = $this->pair();
        $key->delete();
        $this->withToken($key->key)->postJson('/v1/drivers/login', [])->assertUnauthorized();
        $request = \Illuminate\Http\Request::create('/v1/drivers/login', 'OPTIONS');
        $request->headers->set('Authorization', 'Bearer ' . $key->key);
        $result = (new \Fleetbase\Http\Middleware\AuthenticateOnceWithBasicAuth())->authenticatedWithBasic($request);
        self::assertSame(401, $result->getStatusCode());
    }

    public function test_inactive_issuer_and_tenant_mismatch_invalidate_key(): void
    {
        $key = $this->pair();
        DB::table('users')->where('uuid', $this->adminB->uuid)->update(['status' => 'inactive']);
        $this->withToken($key->key)->postJson('/v1/drivers/login', [])->assertUnauthorized();
        DB::table('users')->where('uuid', $this->adminB->uuid)->update(['status' => 'active']);
        DB::table('api_credentials')->where('uuid', $key->uuid)->update(['company_uuid' => $this->adminA->company_uuid]);
        $this->withToken($key->key)->postJson('/v1/drivers/login', [])->assertUnauthorized();
    }

    public function test_real_driver_login_is_bound_to_pairing_and_revocation_is_immediate(): void
    {
        $key = $this->pair();
        $driver = $this->driver($this->adminB);
        $response = $this->withToken($key->key)->postJson('/v1/drivers/login', ['identity' => $driver->email, 'password' => 'S92_test_password_only']);
        $response->assertOk();
        $token = $response->json('token');
        self::assertIsString($token);
        $record = \Laravel\Sanctum\PersonalAccessToken::findToken($token);
        self::assertSame($key->uuid, $record->navigator_credential_uuid);
        self::assertNotNull($record->expires_at);
        $this->withToken($token)->postJson('/v1/orders', [])->assertForbidden();
        $this->credentials->revoke($this->adminB, $key->uuid);
        $this->withToken($token)->getJson('/v1/orders')->assertUnauthorized();
        self::assertNull(\Laravel\Sanctum\PersonalAccessToken::findToken($token));
    }

    public function test_other_company_driver_cannot_login_with_valid_pairing(): void
    {
        $key = $this->pair();
        $driverA = $this->driver($this->adminA);
        $before = DB::table('personal_access_tokens')->count();
        $this->withToken($key->key)->postJson('/v1/drivers/login', ['identity' => $driverA->email, 'password' => 'S92_test_password_only'])->assertUnauthorized();
        self::assertSame($before, DB::table('personal_access_tokens')->count());
    }

    public function test_rotation_requires_new_pairing_and_revokes_only_selected_key(): void
    {
        $old = $this->pair();
        $other = $this->pair();
        $this->credentials->revoke($this->adminB, $old->uuid);
        $new = $this->pair();
        self::assertFalse(NavigatorCredentialScope::valid($old->fresh()));
        self::assertTrue(NavigatorCredentialScope::valid($other->fresh()));
        self::assertTrue(NavigatorCredentialScope::valid($new));
        self::assertNotSame($old->key, $new->key);
    }

    public function test_other_tenant_cannot_revoke_pairing(): void
    {
        $key = $this->pair();
        try {
            $this->credentials->revoke($this->adminA, $key->uuid);
            self::fail('Foreign tenant revocation allowed');
        } catch (\RuntimeException $exception) {
            self::assertTrue(NavigatorCredentialScope::valid($key->fresh()));
        }
    }

    public function test_legacy_link_is_rejected_without_credentials_or_secret_output(): void
    {
        $before = DB::table('api_credentials')->count();
        $this->get('/int/v1/fleet-ops/navigator/link-app?expires=' . (time() + 60) . '&signature=' . str_repeat('0', 64))->assertForbidden();
        self::assertSame($before, DB::table('api_credentials')->count());
    }

    public function test_pairing_redirect_contains_key_with_no_cache_and_no_referrer(): void
    {
        $token = $this->links->issue($this->adminB);
        $response = $this->get('/int/v1/fleet-ops/navigator/link-app?token=' . $token);
        $response->assertStatus(302)->assertHeader('Referrer-Policy', 'no-referrer');
        self::assertStringContainsString('no-store', $response->headers->get('Cache-Control'));
        self::assertStringStartsWith('flbnavigator://configure?', $response->headers->get('Location'));
        self::assertSame(1, DB::table('api_credentials')->where('issuer_user_uuid', $this->adminB->uuid)->count());
        $this->get('/int/v1/fleet-ops/navigator/link-app?token=' . $token)->assertForbidden();
    }

    public function test_wrong_device_type_and_missing_scope_discriminator_fail_closed(): void
    {
        $key = $this->pair();
        DB::table('users')->where('uuid', $key->user_uuid)->update(['type' => 'admin']);
        $this->withToken($key->key)->postJson('/v1/drivers/login')->assertUnauthorized();
        DB::table('users')->where('uuid', $key->user_uuid)->update(['type' => 'navigator-device']);
        DB::table('api_credentials')->where('uuid', $key->uuid)->update(['purpose' => null]);
        $this->withToken($key->key)->getJson('/v1/orders')->assertUnauthorized();
    }

    public function test_login_audit_never_persists_credentials_or_driver_token(): void
    {
        $messages = [];
        Log::listen(function ($event) use (&$messages): void {
            $messages[] = json_encode([$event->message, $event->context]);
        });
        $key = $this->pair();
        $driver = $this->driver($this->adminB);
        $before = DB::table('api_request_logs')->count();
        $response = $this->withToken($key->key)->postJson('/v1/drivers/login', ['identity' => $driver->email, 'password' => 'S92_test_password_only']);
        $response->assertOk();
        $serialized = implode('', $messages) . DB::table(config('activitylog.table_name'))->where('subject_id', $key->uuid)->get()->toJson();
        foreach ([$key->key, $key->secret, $response->json('token'), 'S92_test_password_only'] as $secret) {
            self::assertIsString($secret);
            self::assertStringNotContainsString($secret, $serialized);
        }
        self::assertSame($before, DB::table('api_request_logs')->count());
        self::assertStringContainsString('Navigator API request', $serialized);
    }

    public function test_scoped_sanctum_token_rejects_expiry_and_foreign_profiles(): void
    {
        $key = $this->pair();
        $driver = $this->driver($this->adminB);
        $foreign = $this->driver($this->adminA);
        $response = $this->withToken($key->key)->postJson('/v1/drivers/login', ['identity' => $driver->email, 'password' => 'S92_test_password_only'])->assertOk();
        $token = $response->json('token');
        $profile = DB::table('drivers')->where('user_uuid', $foreign->uuid)->value('public_id');
        $this->withToken($token)->getJson('/v1/drivers/' . $profile)->assertForbidden();
        $this->withToken($token)->getJson('/v1/contacts')->assertForbidden();
        DB::table('api_credentials')->where('uuid', $key->uuid)->update(['expires_at' => now()->subSecond()]);
        $this->withToken($token)->getJson('/v1/orders')->assertUnauthorized();
    }

    public function test_scoped_driver_cannot_operate_another_drivers_order_in_same_company(): void
    {
        $key = $this->pair();
        $driver = $this->driver($this->adminB);
        $other = $this->driver($this->adminB);
        $otherUuid = DB::table('drivers')->where('user_uuid', $other->uuid)->value('uuid');
        $publicId = 'order_' . Str::random(16);
        DB::table('orders')->insert([
            'uuid' => (string) Str::uuid(), 'public_id' => $publicId,
            'company_uuid' => $this->adminB->company_uuid, 'driver_assigned_uuid' => $otherUuid,
        ]);
        $token = $this->withToken($key->key)->postJson('/v1/drivers/login', ['identity' => $driver->email, 'password' => 'S92_test_password_only'])->assertOk()->json('token');
        $this->withToken($token)->getJson('/v1/orders/' . $publicId)->assertForbidden();
        $this->withToken($token)->postJson('/v1/orders/' . $publicId . '/start')->assertForbidden();
        $this->withToken($token)->deleteJson('/v1/orders/' . $publicId)->assertForbidden();
    }

    public function test_scope_migration_rollback_refuses_to_broaden_existing_keys(): void
    {
        $this->pair();
        $migration = require base_path('vendor/fleetbase/core-api/migrations/2026_11_11_000002_add_navigator_credential_scope.php');
        $this->expectException(\RuntimeException::class);
        $migration->down();
    }

    public function test_controller_creation_failure_leaves_link_retryable(): void
    {
        $token = $this->links->issue($this->adminB);
        DB::unprepared("CREATE TRIGGER s92_reject_credential BEFORE INSERT ON api_credentials FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='S92 synthetic issuance failure'");
        try {
            $this->get('/int/v1/fleet-ops/navigator/link-app?token=' . $token)->assertStatus(503);
            self::assertNull(DB::table('fleetops_navigator_link_tokens')->where('token_hash', hash('sha256', $token))->value('consumed_at'));
        } finally {
            DB::unprepared('DROP TRIGGER s92_reject_credential');
        }
        $this->get('/int/v1/fleet-ops/navigator/link-app?token=' . $token)->assertStatus(302);
    }

    public function test_own_tenant_admin_can_rotate_pairing_and_foreign_admin_cannot(): void
    {
        $key = $this->pair();
        $this->actingAs($this->adminA)->postJson('/int/v1/fleet-ops/navigator/pairings/' . $key->uuid . '/rotate')->assertForbidden();
        self::assertTrue(NavigatorCredentialScope::valid($key->fresh()));
        $response = $this->actingAs($this->adminB)->postJson('/int/v1/fleet-ops/navigator/pairings/' . $key->uuid . '/rotate')->assertOk();
        self::assertFalse(NavigatorCredentialScope::valid($key->fresh()));
        parse_str(parse_url($response->json('linkUrl'), PHP_URL_QUERY), $params);
        self::assertIsString($params['token']);
        self::assertInstanceOf(ApiCredential::class, $this->links->redeemWith($params['token'], fn ($issuer) => $this->credentials->issue($issuer)));
    }

    public function test_expired_sanctum_token_and_admin_cookie_do_not_bypass_scoped_identity(): void
    {
        $key = $this->pair();
        $driver = $this->driver($this->adminB);
        $token = $this->withToken($key->key)->postJson('/v1/drivers/login', ['identity' => $driver->email, 'password' => 'S92_test_password_only'])->assertOk()->json('token');
        $this->actingAs($this->adminA)->withToken($token)->postJson('/v1/orders', [])->assertForbidden();
        self::assertSame($driver->uuid, session('user'));
        self::assertFalse(session('is_admin'));
        $access = \Laravel\Sanctum\PersonalAccessToken::findToken($token);
        DB::table('personal_access_tokens')->where('id', $access->id)->update(['expires_at' => now()->subSecond()]);
        $this->withToken($token)->getJson('/v1/orders')->assertUnauthorized();
    }

    public function test_order_lists_are_private_to_driver_even_when_pairing_key_is_shared(): void
    {
        $key = $this->pair();
        $drivers = [$this->driver($this->adminB), $this->driver($this->adminB)];
        $orders = [];
        $tokens = [];
        foreach ($drivers as $user) {
            $profile = DB::table('drivers')->where('user_uuid', $user->uuid)->value('uuid');
            $payload = (string) Str::uuid();
            $id = 'order_' . Str::random(16);
            DB::table('payloads')->insert(['uuid' => $payload, 'company_uuid' => $user->company_uuid]);
            DB::table('orders')->insert(['uuid' => (string) Str::uuid(), 'public_id' => $id, 'company_uuid' => $user->company_uuid, 'driver_assigned_uuid' => $profile, 'payload_uuid' => $payload]);
            $orders[] = $id;
            $tokens[] = $this->withToken($key->key)->postJson('/v1/drivers/login', ['identity' => $user->email, 'password' => 'S92_test_password_only'])->assertOk()->json('token');
        }
        foreach ([0, 1, 0] as $index) {
            $response = $this->withToken($tokens[$index])->getJson('/v1/orders')->assertOk();
            self::assertStringContainsString($orders[$index], $response->getContent());
            self::assertStringNotContainsString($orders[1 - $index], $response->getContent());
            self::assertSame($key->uuid, session('api_credential'));
        }
    }

    public function test_disabled_device_and_unbounded_or_extended_key_lifetime_are_rejected(): void
    {
        $key = $this->pair();
        DB::table('users')->where('uuid', $key->user_uuid)->update(['status' => 'inactive']);
        $this->withToken($key->key)->postJson('/v1/drivers/login')->assertUnauthorized();
        DB::table('users')->where('uuid', $key->user_uuid)->update(['status' => 'active']);
        DB::table('api_credentials')->where('uuid', $key->uuid)->update(['expires_at' => null]);
        $this->withToken($key->key)->postJson('/v1/drivers/login')->assertUnauthorized();
        DB::table('api_credentials')->where('uuid', $key->uuid)->update(['expires_at' => now()->addDays(8)]);
        $this->withToken($key->key)->postJson('/v1/drivers/login')->assertUnauthorized();
    }
}
