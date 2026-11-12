<?php

namespace Tests\Feature;

use Fleetbase\FleetOps\Jobs\FinalizeApiOrderCreation;
use Fleetbase\FleetOps\Jobs\FinalizeInternalOrderCreation;
use ReflectionClass;
use Tests\TestCase;

/**
 * Simulate legacy job payloads serialized before the companyUuid constructor
 * property was introduced. The original payload fields are populated without
 * invoking the new constructor, then serialized and deserialized on Laravel 12.
 */
class Rc1LegacyQueuePayloadTest extends TestCase
{
    public function test_legacy_api_job_payload_fails_closed_before_database_access(): void
    {
        $old = (new ReflectionClass(FinalizeApiOrderCreation::class))->newInstanceWithoutConstructor();
        $old->orderUuid = 'old-order-uuid';
        $old->serviceQuoteUuid = 'old-quote-uuid';
        $old->shouldDispatch = true;

        $replayed = unserialize(serialize($old), ['allowed_classes' => true]);

        $this->assertInstanceOf(FinalizeApiOrderCreation::class, $replayed);
        $this->assertFalse((new \ReflectionProperty($replayed, 'companyUuid'))->isInitialized($replayed));
        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('Queued order finalization is missing its tenant.');
        $replayed->handle();
    }

    public function test_legacy_internal_job_payload_fails_closed_before_database_access(): void
    {
        $old = (new ReflectionClass(FinalizeInternalOrderCreation::class))->newInstanceWithoutConstructor();
        $old->orderUuid = 'old-internal-order-uuid';

        $replayed = unserialize(serialize($old), ['allowed_classes' => true]);

        $this->assertInstanceOf(FinalizeInternalOrderCreation::class, $replayed);
        $this->assertFalse((new \ReflectionProperty($replayed, 'companyUuid'))->isInitialized($replayed));
        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('Queued order finalization is missing its tenant.');
        $replayed->handle();
    }

    public function test_new_api_job_retains_company_in_serialized_payload(): void
    {
        $job = new FinalizeApiOrderCreation('own-order', 'own-quote', false, 'company-a');
        $decoded = unserialize(serialize($job), ['allowed_classes' => true]);
        $this->assertSame('company-a', $decoded->companyUuid);
        $this->assertSame('own-order', $decoded->orderUuid);
        $this->assertSame('own-quote', $decoded->serviceQuoteUuid);
    }

    public function test_new_internal_job_retains_company_in_serialized_payload(): void
    {
        $job = new FinalizeInternalOrderCreation('own-order', 'company-a');
        $decoded = unserialize(serialize($job), ['allowed_classes' => true]);
        $this->assertSame('company-a', $decoded->companyUuid);
        $this->assertSame('own-order', $decoded->orderUuid);
    }
}
