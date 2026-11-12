<?php

namespace App\Exceptions;

use Fleetbase\Exceptions\Handler as ExceptionHandler;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Auth\AuthenticationException;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;

class Handler extends ExceptionHandler
{
    /** Keep expected denials auditable without logging request data or exception messages. */
    public function report(\Throwable $exception)
    {
        $status = match (true) {
            $exception instanceof AuthenticationException => 401,
            $exception instanceof AuthorizationException => $exception->status() ?? 403,
            $exception instanceof HttpExceptionInterface => $exception->getStatusCode(),
            default => null,
        };

        if (in_array($status, [401, 403], true)) {
            // Fleetbase's parent logs ERROR before Laravel's shouldReport() filter.
            Log::notice('security.request_denied', [
                'exception_class' => get_class($exception),
                'status' => $status,
            ]);

            return;
        }

        parent::report($exception);
    }

    /**
     * A list of the inputs that are never flashed for validation exceptions.
     *
     * @var array<int, string>
     */
    protected $dontFlash = [
        'current_password',
        'password',
        'password_confirmation',
    ];
}
