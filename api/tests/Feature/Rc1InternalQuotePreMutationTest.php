<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Http\Controllers\Internal\v1\OrderController;
use Fleetbase\FleetOps\Models\Order;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Tests\TestCase;

/**
 * Execute the real internal controller's pre-create callback in isolation.
 * The model probe will fail if the flow reaches persistence.
 */
class Rc1InternalOrderWriteProbe extends Order
{
    public int $writesAttempted = 0;
    public int $beforeCalls = 0;

    public function createRecordFromRequest($request, ?callable $onBefore = null, ?callable $onAfter = null, array $options = [])
    {
        $input = (array) $request->input('order', []);
        $this->beforeCalls++;
        if ($onBefore) {
            $onBefore($request, $input);
        }

        $this->writesAttempted++;
        throw new \RuntimeException('Foreign quote reached internal order write');
    }
}

class Rc1InternalQuotePreMutationTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        config(['database.default' => 'sqlite']);
        DB::purge('sqlite');
        Schema::connection('sqlite')->create('service_quotes', function ($table) {
            $table->string('uuid')->primary();
            $table->string('public_id')->nullable();
            $table->string('company_uuid');
            $table->timestamp('expired_at')->nullable();
            $table->softDeletes();
        });
        DB::connection('sqlite')->table('service_quotes')->insert([
            'uuid' => '22222222-2222-4222-8222-222222222222',
            'public_id' => 'quote_BBBBBBBB',
            'company_uuid' => 'company-b',
        ]);
        session(['company' => 'company-a']);
    }

    public function test_internal_foreign_uuid_does_not_create_order(): void
    {
        $this->assertNoWrite('22222222-2222-4222-8222-222222222222');
    }

    public function test_internal_public_id_is_rejected_by_request_validation_before_writes(): void
    {
        // The internal service_quote contract accepts UUIDs, not public IDs.
        // Unlike a foreign UUID, this identifier is rejected by validation
        // before the pre-create callback executes.
        $model = new Rc1InternalOrderWriteProbe();
        $controller = new OrderController();
        $controller->model = $model;

        DB::connection('sqlite')->enableQueryLog();
        DB::connection('sqlite')->flushQueryLog();
        $error = null;
        try {
            $controller->createRecord(Request::create('/int/v1/orders', 'POST', [
                'order' => [
                    'order_config_uuid' => 'config-a',
                    'type' => 'transport',
                    'payload' => ['type' => 'transport'],
                    'service_quote' => 'quote_BBBBBBBB',
                ],
            ]));
        } catch (\Illuminate\Validation\ValidationException $exception) {
            $error = $exception;
        }

        $this->assertInstanceOf(\Illuminate\Validation\ValidationException::class, $error);
        $this->assertSame(422, $error->getResponse()?->getStatusCode());
        $this->assertSame(0, $model->beforeCalls);
        $this->assertSame(0, $model->writesAttempted);
        foreach (DB::connection('sqlite')->getQueryLog() as $query) {
            $this->assertDoesNotMatchRegularExpression('/^(insert|update|delete|replace|create|drop|alter)\b/i', ltrim($query['query']));
        }
    }

    private function assertNoWrite(string $reference): void
    {
        $model = new Rc1InternalOrderWriteProbe();
        $controller = new OrderController();
        $controller->model = $model;

        DB::connection('sqlite')->enableQueryLog();
        DB::connection('sqlite')->flushQueryLog();
        $response = $controller->createRecord(Request::create('/int/v1/orders', 'POST', [
            'order' => [
                'order_config_uuid' => 'config-a',
                'type' => 'transport',
                'payload' => ['type' => 'transport'],
                'service_quote' => $reference,
            ],
        ]));

        $this->assertSame(0, $model->writesAttempted);
        $this->assertGreaterThanOrEqual(1, $model->beforeCalls);
        $this->assertInstanceOf(\Illuminate\Http\JsonResponse::class, $response);
        $body = $response->getData(true);
        $this->assertStringContainsString('Invalid service quote', json_encode($body));
        foreach (DB::connection('sqlite')->getQueryLog() as $query) {
            $sql = strtolower(ltrim($query['query']));
            $this->assertDoesNotMatchRegularExpression('/^(insert|update|delete|replace|create|drop|alter)\b/', $sql);
        }
        $this->assertSame(0, DB::connection('sqlite')->table('service_quotes')->where('company_uuid', 'company-a')->count());
    }
}
