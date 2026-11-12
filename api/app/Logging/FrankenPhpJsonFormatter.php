<?php

namespace App\Logging;

use Monolog\Formatter\JsonFormatter;
use Monolog\LogRecord;

/** Bridge Monolog records to Octane's Caddy msg / raw-stream protocol. */
class FrankenPhpJsonFormatter extends JsonFormatter
{
    public function format(LogRecord $record): string
    {
        $stream = $this->normalizeRecord($record);
        $stream['type'] = 'raw';

        // A JSON msg invokes Octane::handleStream(), preserving level/context as
        // structured JSON instead of its lossy "unknown error" console fallback.
        return $this->toJson([
            'level' => strtolower($record->level->getName()),
            'msg' => $this->toJson($stream, true),
        ], true) . ($this->appendNewline ? "\n" : '');
    }
}
