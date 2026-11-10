<?php

// Laravel Sanctum 4 publishes this migration but does not run it automatically.
// Keep its original timestamp so the personal_access_tokens table exists before
// Core API's 2023_04_25_094311_fix_personal_access_tokens migration changes
// tokenable_id from the Sanctum default to Fleetbase's UUID representation.
// Do not silently skip this creation: a fresh installation must fail closed
// if the table cannot be created.

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('personal_access_tokens', function (Blueprint $table) {
            $table->id();
            $table->morphs('tokenable');
            $table->text('name');
            $table->string('token', 64)->unique();
            $table->text('abilities')->nullable();
            $table->timestamp('last_used_at')->nullable();
            $table->timestamp('expires_at')->nullable()->index();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('personal_access_tokens');
    }
};
