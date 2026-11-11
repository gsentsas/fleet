<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Models\ServiceQuote;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

/** Real FleetOps quote resolver, exercised against disposable CI MySQL. */
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
        Schema::connection('mysql')->create('service_quotes', function ($table) {
            $table->string('uuid', 36)->primary();
            $table->string('public_id', 80)->unique();
            $table->string('company_uuid', 36);
            $table->timestamp('expired_at')->nullable();
            $table->softDeletes();
            $table->timestamps();
        });
        DB::connection('mysql')->table('service_quotes')->insert([
            ['uuid' => '11111111-1111-4111-8111-111111111111', 'public_id' => 'quote_AAAAAAAA', 'company_uuid' => 'company-a'],
            ['uuid' => '22222222-2222-4222-8222-222222222222', 'public_id' => 'quote_BBBBBBBB', 'company_uuid' => 'company-b'],
        ]);
    }

    protected function tearDown(): void
    {
        try {
            if (getenv('RC1_EPHEMERAL_MYSQL') === '1' &&
                config('database.connections.mysql.database') === 'rc1_ci_tenant') {
                Schema::connection('mysql')->dropIfExists('service_quotes');
            }
        } finally {
            parent::tearDown();
        }
    }

    public function test_foreign_uuid_and_public_id_are_not_visible_to_tenant(): void
    {
        session(['company' => 'company-a']);
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
