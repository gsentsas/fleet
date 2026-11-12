<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Http\Controllers\Api\v1\OrderController;
use Fleetbase\FleetOps\Http\Requests\CreateOrderRequest;
use Fleetbase\FleetOps\Models\Order;
use Fleetbase\FleetOps\Models\OrderConfig;
use Fleetbase\FleetOps\Models\ServiceQuote;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Tests\TestCase;

class Rc1InvalidQuoteOrderProbe extends OrderController
{
    public int $writesAttempted = 0;

    protected function resolveOrderConfig(array $input): ?OrderConfig
    {
        $config = new OrderConfig();
        $config->setRawAttributes(['uuid' => 'config-a', 'key' => 'transport'], true);

        return $config;
    }

    protected function sessionCompany(): ?string
    {
        return 'company-a';
    }

    protected function resolveServiceQuote(Request $request): ?ServiceQuote
    {
        // Models the lookup result for a quote owned by a different tenant.
        return null;
    }

    protected function createOrder(array $input): Order
    {
        $this->writesAttempted++;
        throw new \RuntimeException('Invalid quote reached createOrder');
    }

    protected function newPayload(): \Fleetbase\FleetOps\Models\Payload
    {
        $this->writesAttempted++;
        throw new \RuntimeException('Invalid quote reached payload creation');
    }
}

class Rc1QuotePreMutationTest extends TestCase
{
    public function test_invalid_explicit_uuid_is_rejected_before_creation(): void
    {
        $this->assertDeniedWithoutWrites('22222222-2222-4222-8222-222222222222');
    }

    public function test_invalid_explicit_public_id_is_rejected_before_creation(): void
    {
        $this->assertDeniedWithoutWrites('quote_BBBBBBBB');
    }

    private function assertDeniedWithoutWrites(string $reference): void
    {
        $controller = new Rc1InvalidQuoteOrderProbe();

        DB::connection()->enableQueryLog();
        DB::connection()->flushQueryLog();

        $request = CreateOrderRequest::create('/v1/orders', 'POST', [
            'type' => 'transport',
            'service_quote' => $reference,
        ]);
        $request->setContainer($this->app);
        $result = $controller->create($request);

        $this->assertSame(422, $result->getStatusCode());
        $this->assertSame(0, $controller->writesAttempted);
        $this->assertSame([], DB::connection()->getQueryLog());
    }
}
