<?php

namespace Tests\Unit;

use App\Exceptions\Handler;
use App\Logging\FrankenPhpJsonFormatter;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Auth\AuthenticationException;
use Illuminate\Console\OutputStyle;
use Illuminate\Console\View\Components\Factory;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Route;
use Laravel\Octane\Commands\StartFrankenPhpCommand;
use Monolog\Formatter\JsonFormatter;
use Monolog\Level;
use Monolog\LogRecord;
use Symfony\Component\Console\Input\ArrayInput;
use Symfony\Component\Console\Output\BufferedOutput;
use Symfony\Component\HttpKernel\Exception\AccessDeniedHttpException;
use Symfony\Component\HttpKernel\Exception\HttpException;
use Tests\TestCase;

class Rc1OctaneOutputProbe extends StartFrankenPhpCommand
{
    private string $wire = '';

    public function capture(string $wire): string
    {
        $this->wire = $wire;
        $this->setLaravel(app());
        $this->input = new ArrayInput([], $this->getDefinition());
        $buffer = new BufferedOutput();
        $this->output = new OutputStyle($this->input, $buffer);
        $this->components = new Factory($this->output);
        $this->writeServerOutput(null);

        return $buffer->fetch();
    }

    protected function getServerOutput($server)
    {
        return ['', $this->wire];
    }

    public function raw($string)
    {
        // Capture the final sink; all parsing/dispatch stays in the locked Octane code.
        $this->output->writeln($string);
    }
}

class Rc1OctaneLoggingTest extends TestCase
{
    public function test_real_octane_parser_mislabels_legacy_monolog_record_without_msg(): void
    {
        $record = new LogRecord(new \DateTimeImmutable(), 'testing', Level::Notice, 'synthetic diagnostic event');
        $wire = (new JsonFormatter())->format($record);

        $this->assertArrayNotHasKey('msg', json_decode($wire, true));
        $this->assertStringContainsString('unknown error', (new Rc1OctaneOutputProbe())->capture($wire));
    }

    public function test_vendor_handler_logs_ignored_authentication_exception_as_error_before_laravel_filter(): void
    {
        Log::spy();
        $legacy = new \Fleetbase\Exceptions\Handler($this->app);
        $exception = new AuthenticationException();

        $this->assertFalse($legacy->shouldReport($exception));
        $legacy->report($exception);

        Log::shouldHaveReceived('error')->once();
    }

    public function test_formatter_preserves_every_level_and_structured_context_through_real_octane_parser(): void
    {
        foreach (Level::cases() as $level) {
            $record = new LogRecord(new \DateTimeImmutable(), 'testing', $level, 'synthetic event', ['status' => 500]);
            $wire = (new FrankenPhpJsonFormatter())->format($record);
            $output = (new Rc1OctaneOutputProbe())->capture($wire);
            $decoded = json_decode(trim($output), true, 512, JSON_THROW_ON_ERROR);

            self::assertSame('raw', $decoded['type']);
            self::assertSame($level->value, $decoded['level']);
            self::assertSame($level->getName(), $decoded['level_name']);
            self::assertSame('synthetic event', $decoded['message']);
            self::assertSame(['status' => 500], $decoded['context']);
            self::assertStringNotContainsString('unknown error', $output);
        }
    }

    public function test_expected_denials_have_minimal_notice_audit_without_sensitive_exception_or_request_data(): void
    {
        Log::spy();
        $handler = new Handler($this->app);
        $canary = 'r49-synthetic-sensitive-canary';
        $this->app->instance('request', \Illuminate\Http\Request::create('/?token=' . $canary, 'GET', [], [], [], ['HTTP_AUTHORIZATION' => 'Bearer ' . $canary]));
        $exceptions = [
            new AuthenticationException($canary),
            new AuthorizationException($canary),
            new AccessDeniedHttpException($canary),
            new HttpException(401, $canary),
        ];
        foreach ($exceptions as $exception) {
            $handler->report($exception);
            $status = $exception instanceof AuthenticationException || ($exception instanceof HttpException && $exception->getStatusCode() === 401) ? 401 : 403;
            Log::shouldHaveReceived('notice')->with('security.request_denied', [
                'exception_class' => get_class($exception), 'status' => $status,
            ])->once();
        }
        Log::shouldNotHaveReceived('error');
    }

    public function test_denials_keep_http_status_and_real_500_is_still_reported_as_error(): void
    {
        config(['app.debug' => false]);
        Log::spy();
        Route::get('/r49-test-unauthenticated', fn () => throw new AuthenticationException());
        Route::get('/r49-test-forbidden', fn () => throw new AuthorizationException());
        Route::get('/r49-test-internal', fn () => throw new \RuntimeException('synthetic internal failure'));

        $this->getJson('/r49-test-unauthenticated')->assertStatus(401)->assertJsonStructure(['errors']);
        $this->getJson('/r49-test-forbidden')->assertStatus(403)->assertJsonStructure(['errors']);
        $this->getJson('/r49-test-internal')->assertStatus(500)->assertExactJson(['errors' => ['Server Error']]);
        Log::shouldHaveReceived('error')->withArgs(fn ($message) => is_string($message)
            && str_contains($message, 'synthetic internal failure'))->atLeast()->once();
    }
}
