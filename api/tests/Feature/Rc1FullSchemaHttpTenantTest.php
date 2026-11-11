<?php

namespace Tests\Feature;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

/**
 * @group rc1-mysql-only
 * S49: registered Fleetbase HTTP middlewares on real migrated disposable MySQL.
 * No schema creation, migration, fake middleware or production access in this test.
 */
class Rc1FullSchemaHttpTenantTest extends TestCase
{
    private const COMPANY_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab';
    private const COMPANY_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    private const USER_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    private const CREDENTIAL = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    private const QUOTE_B = '22222222-2222-4222-8222-222222222222';
    private const TOKEN = 'flb_live_S49_synthetic_company_a_ci_only';

    protected function setUp(): void
    {
        parent::setUp();

        if (getenv('RC1_FULL_SCHEMA_MYSQL') !== '1'
            || config('database.default') !== 'mysql'
            || config('database.connections.mysql.database') !== 'rc1_ci_schema'
            || config('app.env') !== 'testing') {
            $this->fail('STOP=S49_REQUIRES_PINNED_DISPOSABLE_FULL_MYSQL_SCHEMA');
        }

        foreach (['migrations', 'users', 'companies', 'api_credentials', 'service_quotes', 'orders', 'api_request_logs'] as $table) {
            $this->assertTrue(Schema::connection('mysql')->hasTable($table), 'S49 migration table missing: ' . $table);
        }
        $this->assertGreaterThanOrEqual(391, DB::connection('mysql')->table('migrations')->count(), 'S49 requires complete S48 migration replay');

        $db = DB::connection('mysql');
        // Real migrated foreign keys: create companies with nullable owner first,
        // then owner user and credential. All identifiers are synthetic CI fixtures.
        $db->table('companies')->insert([
            ['uuid' => self::COMPANY_A, 'name' => 'S49 test tenant A'],
            ['uuid' => self::COMPANY_B, 'name' => 'S49 test tenant B'],
        ]);
        $db->table('users')->insert([
            'uuid' => self::USER_A,
            'company_uuid' => self::COMPANY_A,
            'type' => 'admin',
        ]);
        $db->table('companies')->where('uuid', self::COMPANY_A)->update(['owner_uuid' => self::USER_A]);
        $db->table('api_credentials')->insert([
            'uuid' => self::CREDENTIAL,
            'user_uuid' => self::USER_A,
            'company_uuid' => self::COMPANY_A,
            'key' => self::TOKEN,
            'test_mode' => 0,
        ]);
        $db->table('service_quotes')->insert([
            'uuid' => self::QUOTE_B,
            'public_id' => 'quote_S49_FOREIGN',
            'amount' => 100,
            'company_uuid' => self::COMPANY_B,
        ]);
    }

    public function test_authenticated_foreign_quote_is_rejected_without_order_on_full_migrations(): void
    {
        $db = DB::connection('mysql');
        $beforeOrders = $db->table('orders')->count();
        $beforeQuotes = $db->table('service_quotes')->count();
        $beforeAudit = $db->table('api_request_logs')->count();
        $this->assertSame(0, $beforeOrders);

        $response = $this->withToken(self::TOKEN)->postJson('/v1/orders', [
            'type' => 'transport',
            'service_quote' => self::QUOTE_B,
        ]);

        $this->assertSame(422, $response->getStatusCode(), 'S49 must reject foreign quote through real middleware');
        $this->assertSame($beforeOrders, $db->table('orders')->count(), 'S49 no order created');
        $this->assertSame($beforeQuotes, $db->table('service_quotes')->count(), 'S49 quote fixture not modified');
        $this->assertSame(self::COMPANY_A, session('company'), 'S49 tenant must be derived from authenticated key');
        $this->assertNotNull($db->table('api_credentials')->where('uuid', self::CREDENTIAL)->value('last_used_at'), 'S49 real API auth must mark key used');

        $audit = $db->table('api_request_logs')
            ->where('method', 'POST')
            ->where('path', 'v1/orders')
            ->where('status_code', '422')
            ->where('company_uuid', self::COMPANY_A)
            ->first();
        $this->assertGreaterThan($beforeAudit, $db->table('api_request_logs')->count(), 'S49 real logger must insert an audit record');
        $this->assertNotNull($audit, 'S49 must record 422 with authenticated tenant identity');
    }
}
