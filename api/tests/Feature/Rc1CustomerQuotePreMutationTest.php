<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Http\Controllers\Api\v1\CustomerController;
use Fleetbase\FleetOps\Http\Requests\CreateCustomerOrderRequest;
use Fleetbase\FleetOps\Models\Contact;
use Fleetbase\FleetOps\Models\Order;
use Fleetbase\FleetOps\Models\OrderConfig;
use Illuminate\Support\Facades\DB;
use Tests\TestCase;

class Rc1CustomerQuoteControllerProbe extends CustomerController
{
    public int $writesAttempted = 0;

    protected function currentCustomer(): ?Contact
    {
        $contact = new Contact();
        $contact->setRawAttributes(['uuid' => 'customer-a', 'company_uuid' => 'company-a'], true);

        return $contact;
    }

    protected function sessionCompany(): ?string
    {
        return 'company-a';
    }

    protected function resolveOrderConfig(CreateCustomerOrderRequest $request, string $companyUuid): ?OrderConfig
    {
        $config = new OrderConfig();
        $config->setRawAttributes(['uuid' => 'config-a', 'key' => 'transport'], true);

        return $config;
    }

    protected function resolveServiceQuote(CreateCustomerOrderRequest $request): mixed
    {
        // A foreign/unknown reference has no record in the authenticated company.
        return null;
    }

    protected function createOrderRecord(array $attributes): Order
    {
        $this->writesAttempted++;
        throw new \RuntimeException('Foreign quote reached order creation');
    }

    protected function buildPayloadFromInput(array $input, string $companyUuid): \Fleetbase\FleetOps\Models\Payload
    {
        $this->writesAttempted++;
        throw new \RuntimeException('Foreign quote reached payload creation');
    }
}

class Rc1CustomerQuotePreMutationTest extends TestCase
{
    public function test_customer_foreign_uuid_is_rejected_before_writes(): void
    {
        $this->assertRejectedWithoutWrites('22222222-2222-4222-8222-222222222222');
    }

    public function test_customer_foreign_public_id_is_rejected_before_writes(): void
    {
        $this->assertRejectedWithoutWrites('quote_BBBBBBBB');
    }

    private function assertRejectedWithoutWrites(string $quote): void
    {
        $controller = new Rc1CustomerQuoteControllerProbe();
        DB::connection()->enableQueryLog();
        DB::connection()->flushQueryLog();
        $request = CreateCustomerOrderRequest::create('/v1/customers/orders', 'POST', [
            'type' => 'transport',
            'service_quote' => $quote,
        ]);
        $request->setContainer($this->app);

        $response = $controller->createOrder($request);

        $this->assertSame(422, $response->getStatusCode());
        $this->assertSame(0, $controller->writesAttempted);
        $this->assertSame([], DB::connection()->getQueryLog());
    }
}
