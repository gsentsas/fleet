<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Models\ServiceQuote;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

/** Real FleetOps quote resolver, exercised against disposable CI MySQL. */
/** @group rc1-mysql-only */
class Rc1MySqlQuoteTenantBoundaryTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        if (getenv('RC1_EPHEMERAL_MYSQL') !== '1' ||
            config('database.connections.mysql.database') !== 'rc1_ci_tenant' ||
            config('database.default') !== 'mysql') {
            $this->fail('STOP=NOT_AN_EXPLICIT_EPHEMERAL_MYSQL_CI_DATABASE');
        }
        // Minimal installation markers required by the actual global
        // EnsureFleetbaseConfigured middleware. Ephemeral CI database only.
        foreach (['settings', 'users', 'companies'] as $table) {
            Schema::connection('mysql')->create($table, function ($blueprint) use ($table) {
                $blueprint->string('uuid', 36)->primary();
                if ($table === 'users') {
                    $blueprint->string('company_uuid', 36)->nullable();
                    $blueprint->string('type', 30)->nullable();
                    $blueprint->softDeletes();
                }
                if ($table === 'companies') {
                    $blueprint->string('owner_uuid', 36)->nullable();
                    $blueprint->softDeletes();
                }
                if ($table === 'settings') {
                    // The actual MergeConfigFromSettings middleware selects key/value.
                    $blueprint->string('key')->unique();
                    $blueprint->text('value')->nullable();
                }
            });
        }
        Schema::connection('mysql')->create('activity', function ($table) {
            $table->string('uuid', 36)->primary();
            $table->string('log_name')->nullable();
            $table->text('description')->nullable();
            $table->string('subject_type')->nullable();
            $table->string('subject_id')->nullable();
            $table->string('causer_type')->nullable();
            $table->string('causer_id')->nullable();
            $table->json('properties')->nullable();
            $table->string('event')->nullable();
            $table->string('company_id')->nullable();
            $table->string('batch_uuid')->nullable();
            $table->timestamps();
        });
        Schema::connection('mysql')->create('personal_access_tokens', function ($table) {
            $table->bigIncrements('id');
            $table->string('token', 64)->unique();
            $table->string('tokenable_type')->nullable();
            $table->unsignedBigInteger('tokenable_id')->nullable();
        });
        Schema::connection('mysql')->create('api_credentials', function ($table) {
            $table->string('uuid', 36)->primary();
            $table->string('user_uuid', 36);
            $table->string('company_uuid', 36);
            $table->string('key', 120)->unique();
            $table->string('secret')->nullable();
            $table->boolean('test_mode')->default(false);
            $table->timestamp('last_used_at')->nullable();
            $table->timestamp('expires_at')->nullable();
            $table->softDeletes();
            $table->timestamps();
        });
        Schema::connection('mysql')->create('service_quotes', function ($table) {
            $table->string('uuid', 36)->primary();
            $table->string('public_id', 80)->unique();
            $table->string('company_uuid', 36);
            $table->timestamp('expired_at')->nullable();
            $table->softDeletes();
            $table->timestamps();
        });
        DB::connection('mysql')->table('users')->insert([
            'uuid' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'company_uuid' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab',
            'type' => 'admin',
        ]);
        DB::connection('mysql')->table('companies')->insert([
            'uuid' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab',
            'owner_uuid' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ]);
        DB::connection('mysql')->table('api_credentials')->insert([
            'uuid' => 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'user_uuid' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'company_uuid' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab',
            'key' => 'flb_live_S45_synthetic_company_a_ci_only',
            'test_mode' => 0,
        ]);
        DB::connection('mysql')->table('service_quotes')->insert([
            ['uuid' => '11111111-1111-4111-8111-111111111111', 'public_id' => 'quote_AAAAAAAA', 'company_uuid' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab'],
            ['uuid' => '22222222-2222-4222-8222-222222222222', 'public_id' => 'quote_BBBBBBBB', 'company_uuid' => 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'],
        ]);
    }

    protected function tearDown(): void
    {
        try {
            if (getenv('RC1_EPHEMERAL_MYSQL') === '1' &&
                config('database.connections.mysql.database') === 'rc1_ci_tenant') {
                Schema::connection('mysql')->dropIfExists('service_quotes');
                Schema::connection('mysql')->dropIfExists('api_credentials');
                Schema::connection('mysql')->dropIfExists('personal_access_tokens');
                Schema::connection('mysql')->dropIfExists('activity');
                foreach (['settings', 'users', 'companies'] as $table) {
                    Schema::connection('mysql')->dropIfExists($table);
                }
            }
        } finally {
            parent::tearDown();
        }
    }

    public function test_foreign_uuid_and_public_id_are_not_visible_to_tenant(): void
    {
        session(['company' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab']);
        $this->assertNoWriteLookup('22222222-2222-4222-8222-222222222222', false);
        $this->assertNoWriteLookup('quote_BBBBBBBB', false);
        $this->assertNoWriteLookup('11111111-1111-4111-8111-111111111111', true);
        $this->assertNoWriteLookup('quote_AAAAAAAA', true);
    }

    public function test_missing_company_context_fails_closed_without_sql(): void
    {
        session()->forget('company');
        $this->assertNoWriteLookup('22222222-2222-4222-8222-222222222222', false, true);
    }

    public function test_unauthenticated_order_creation_is_rejected_by_http_boundary(): void
    {
        $conn = DB::connection('mysql');
        $before = $conn->table('service_quotes')->orderBy('uuid')->get(['uuid', 'company_uuid'])->toJson();
        $conn->enableQueryLog();
        $conn->flushQueryLog();
        $response = $this->postJson('/v1/orders', [
            'type' => 'transport',
            'service_quote' => '22222222-2222-4222-8222-222222222222',
        ]);
        $queries = $conn->getQueryLog();
        $conn->disableQueryLog();
        $this->assertContains($response->getStatusCode(), [401, 403], 'Missing API credential must be denied by HTTP auth, not 500 or 404');
        foreach ($queries as $entry) {
            $this->assertDoesNotMatchRegularExpression('/^(insert|update|delete|replace|create|drop|alter|truncate)\b/i', ltrim($entry['query']));
        }
        $this->assertSame($before, $conn->table('service_quotes')->orderBy('uuid')->get(['uuid', 'company_uuid'])->toJson());
    }

    public function test_authenticated_company_a_cannot_order_using_company_b_quote(): void
    {
        $conn = DB::connection('mysql');
        $before = $conn->table('service_quotes')->orderBy('uuid')->get(['uuid', 'company_uuid'])->toJson();
        $credential = \Fleetbase\Models\ApiCredential::on('mysql')
            ->where('key', 'flb_live_S45_synthetic_company_a_ci_only')
            ->with(['company.owner'])->withoutGlobalScopes()->first();
        $this->assertNotNull($credential, 'Synthetic API credential must resolve');
        $this->assertNotNull($credential->company, 'Synthetic tenant company must resolve');
        $this->assertNotNull($credential->company->owner, 'Synthetic company owner must resolve');
        $this->assertNotNull(\Fleetbase\Models\User::find($credential->user_uuid), 'Synthetic auth user must resolve');
        $this->assertFalse($credential->trashed(), 'Synthetic API credential must not be soft-deleted');
        $this->assertFalse($credential->hasExpired(), 'Synthetic API credential must not be expired');
        $response = $this->withToken('flb_live_S45_synthetic_company_a_ci_only')
            ->postJson('/v1/orders', [
                'type' => 'transport',
                'service_quote' => '22222222-2222-4222-8222-222222222222',
            ]);
        $this->assertSame(422, $response->getStatusCode(), 'Authenticated tenant must reject foreign quote before order creation; response=' . substr(str_replace('flb_live_S45_synthetic_company_a_ci_only', '[REDACTED]', (string) $response->getContent()), 0, 250) . '; auth_last_used=' . ($conn->table('api_credentials')->where('uuid', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc')->value('last_used_at') ? 'YES' : 'NO'));
        $this->assertSame($before, $conn->table('service_quotes')->orderBy('uuid')->get(['uuid', 'company_uuid'])->toJson());
        $this->assertSame('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab', session('company'), 'Authentication must derive tenant from credential');
        $this->assertNotNull($conn->table('api_credentials')->where('uuid', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc')->value('last_used_at'), 'Real API auth must update credential last-used timestamp');
    }

    private function assertNoWriteLookup(string $reference, bool $visible, bool $expectNoSql = false): void
    {
        $conn = DB::connection('mysql');
        $before = $conn->table('service_quotes')->orderBy('uuid')->get(['uuid', 'company_uuid'])->toJson();
        $conn->enableQueryLog();
        $conn->flushQueryLog();
        $result = ServiceQuote::resolveFromRequest(Request::create('/v1/orders', 'POST', ['service_quote' => $reference]));
        $queries = $conn->getQueryLog();
        $conn->disableQueryLog();
        $this->assertSame($visible, $result instanceof ServiceQuote);
        if ($expectNoSql) $this->assertSame([], $queries);
        foreach ($queries as $entry) {
            $this->assertDoesNotMatchRegularExpression('/^(insert|update|delete|replace|create|drop|alter|truncate)\b/i', ltrim($entry['query']));
        }
        $this->assertSame($before, $conn->table('service_quotes')->orderBy('uuid')->get(['uuid', 'company_uuid'])->toJson());
    }
}
