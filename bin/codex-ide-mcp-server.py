#!/usr/bin/env python3
"""Minimal MCP bridge backed by a running Emacs instance."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
from typing import Any


PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "codex-ide-emacs-bridge", "version": "0.1.0"}
DEBUG_LOG_PATH: str | None = None
DEFAULT_EMACSCLIENT_TIMEOUT_SEC = 55.0


class ProtocolError(Exception):
    def __init__(self, code: int, message: str, request_id: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.request_id = request_id


def json_dumps(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def debug_log(*parts: object) -> None:
    if not DEBUG_LOG_PATH:
        return
    try:
        fd = os.open(DEBUG_LOG_PATH, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.fchmod(fd, 0o600)
        except OSError:
            pass
        with os.fdopen(fd, "a", encoding="utf-8") as handle:
            print(*parts, file=handle)
    except OSError:
        pass


def debug_bytes(label: str, value: bytes) -> None:
    debug_log(f"{label}: {len(value)} bytes")


def parse_json_message(body: bytes) -> dict[str, Any]:
    try:
        message = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(-32700, f"Parse error: {exc}") from exc
    if not isinstance(message, dict):
        raise ProtocolError(-32600, "Invalid Request: message must be a JSON object")
    return message


def read_header_framed_message(first_line: bytes) -> dict[str, Any]:
    content_length: int | None = None
    line = first_line
    while True:
        debug_bytes("stdin header", line)
        if line in (b"\r\n", b"\n"):
            break
        try:
            header = line.decode("ascii").strip()
        except UnicodeDecodeError as exc:
            raise ProtocolError(-32700, f"Parse error: invalid header encoding: {exc}") from exc
        if ":" not in header:
            raise ProtocolError(-32700, f"Parse error: invalid header: {header}")
        key, value = header.split(":", 1)
        if key.lower() == "content-length":
            try:
                content_length = int(value.strip())
            except ValueError as exc:
                raise ProtocolError(-32700, f"Parse error: invalid Content-Length: {value.strip()}") from exc
        line = sys.stdin.buffer.readline()
        if not line:
            raise ProtocolError(-32700, "Parse error: EOF while reading headers")

    if content_length is None:
        raise ProtocolError(-32700, "Parse error: missing Content-Length")
    body = sys.stdin.buffer.read(content_length)
    debug_bytes("stdin body", body)
    if len(body) != content_length:
        raise ProtocolError(-32700, "Parse error: EOF while reading message body")
    return parse_json_message(body)


def read_message() -> dict[str, Any] | None:
    while True:
        line = sys.stdin.buffer.readline()
        debug_bytes("stdin line", line)
        if not line:
            debug_log("stdin closed before message")
            return None
        if line in (b"\r\n", b"\n"):
            continue
        if line.lower().startswith(b"content-length:"):
            return read_header_framed_message(line)
        return parse_json_message(line)


def write_message(payload: dict[str, Any]) -> None:
    body = json_dumps(payload)
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.write(b"\n")
    sys.stdout.buffer.flush()


class EmacsProxy:
    def __init__(
        self,
        emacsclient: str,
        server_name: str | None,
        timeout_sec: float,
        allowed_roots: list[str],
    ) -> None:
        self.emacsclient = emacsclient
        self.server_name = server_name
        self.timeout_sec = timeout_sec
        self.allowed_roots = allowed_roots
        self._tool_catalog: list[dict[str, Any]] | None = None
        self._tool_names: set[str] | None = None

    def _elisp_string(self, value: str) -> str:
        return json.dumps(value, ensure_ascii=True)

    def _tool_call_expression(self, name: str, params: dict[str, Any]) -> str:
        payload = json.dumps(
            {
                "name": name,
                "params": params,
                "meta": {"allowedRoots": self.allowed_roots},
            },
            separators=(",", ":"),
            ensure_ascii=True,
        )
        return (
            "(base64-encode-string "
            f"(encode-coding-string (codex-ide-mcp-bridge--json-tool-call {self._elisp_string(payload)}) 'utf-8) t)"
        )

    def _catalog_expression(self) -> str:
        return (
            "(base64-encode-string "
            "(encode-coding-string (codex-ide-mcp-bridge--json-tool-catalog) 'utf-8) t)"
        )

    def _run_expression(self, expression: str, operation: str) -> Any:
        command = [self.emacsclient]
        if self.server_name:
            command.extend(["-s", self.server_name])
        command.extend(["--eval", expression])
        debug_log(
            f"{operation} command:",
            f"argc={len(command)}",
            f"server_name={'set' if self.server_name else 'default'}",
            f"allowed_roots={len(self.allowed_roots)}",
        )
        started = time.monotonic()
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                check=False,
                timeout=self.timeout_sec,
            )
        except subprocess.TimeoutExpired as exc:
            elapsed = time.monotonic() - started
            debug_log(f"{operation} timed out after {elapsed:.3f}s")
            debug_bytes(f"{operation} stdout", exc.stdout or b"")
            debug_bytes(f"{operation} stderr", exc.stderr or b"")
            raise RuntimeError(f"emacsclient timed out after {self.timeout_sec:g}s") from exc
        elapsed = time.monotonic() - started
        debug_log(f"{operation} return code: {completed.returncode} elapsed: {elapsed:.3f}s")
        debug_bytes(f"{operation} stdout", completed.stdout)
        debug_bytes(f"{operation} stderr", completed.stderr)
        if completed.returncode != 0:
            stderr = completed.stderr.strip() or completed.stdout.strip() or b"emacsclient failed"
            raise RuntimeError(stderr.decode("utf-8", errors="replace"))
        try:
            encoded = json.loads(completed.stdout.decode("utf-8"))
            if not isinstance(encoded, str):
                raise RuntimeError("invalid bridge response: expected base64 string")
            decoded = base64.b64decode(encoded)
            return json.loads(decoded.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, base64.binascii.Error) as exc:
            raise RuntimeError(f"invalid bridge response: {exc}") from exc

    def tool_catalog(self) -> list[dict[str, Any]]:
        if self._tool_catalog is not None:
            return self._tool_catalog
        catalog = self._run_expression(self._catalog_expression(), "catalog")
        if not isinstance(catalog, list) or not catalog:
            raise RuntimeError("invalid bridge catalog")
        names: set[str] = set()
        public_catalog: list[dict[str, Any]] = []
        for item in catalog:
            if not isinstance(item, dict) or set(item) != {
                "name",
                "description",
                "inputSchema",
            }:
                raise RuntimeError("invalid bridge catalog")
            name = item["name"]
            description = item["description"]
            schema = item["inputSchema"]
            if (
                not isinstance(name, str)
                or not name
                or name in names
                or not isinstance(description, str)
                or not description
                or not isinstance(schema, dict)
                or schema.get("type") != "object"
                or not isinstance(schema.get("properties"), dict)
                or schema.get("additionalProperties") is not False
            ):
                raise RuntimeError("invalid bridge catalog")
            names.add(name)
            public_catalog.append(
                {
                    "name": name,
                    "description": description,
                    "inputSchema": schema,
                }
            )
        self._tool_catalog = public_catalog
        self._tool_names = names
        return self._tool_catalog

    def call_tool(self, name: str, params: dict[str, Any] | None = None) -> Any:
        params = params or {}
        self.tool_catalog()
        if self._tool_names is None or name not in self._tool_names:
            raise RuntimeError("unknown bridge tool")
        return self._run_expression(
            self._tool_call_expression(name, params),
            f"dispatch {name}",
        )


def text_result(text: str, *, is_error: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


def structured_result(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(result, indent=2, sort_keys=True),
            }
        ],
        "structuredContent": result,
    }


def handle_tool_call(proxy: EmacsProxy, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(arguments, dict):
        return text_result("Invalid tool arguments: expected object", is_error=True)
    try:
        result = proxy.call_tool(name, arguments)
    except RuntimeError as exc:
        if str(exc) == "unknown bridge tool":
            return text_result("Unknown tool", is_error=True)
        raise
    if isinstance(result, dict):
        return structured_result(result)
    return text_result(json.dumps(result, indent=2, sort_keys=True))


def error_response(code: int, message: str, request_id: Any = None) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {
            "code": code,
            "message": message,
        },
    }


def main() -> int:
    global DEBUG_LOG_PATH
    debug_log("--- mcp process start ---")
    parser = argparse.ArgumentParser()
    parser.add_argument("--emacsclient", default="emacsclient")
    parser.add_argument("--server-name", default=None)
    parser.add_argument("--emacsclient-timeout", type=float, default=DEFAULT_EMACSCLIENT_TIMEOUT_SEC)
    parser.add_argument(
        "--allowed-root",
        action="append",
        default=[],
        help="Emacs-visible filesystem root allowed for bridge file tools. May be repeated.",
    )
    parser.add_argument(
        "--debug-log",
        default=None,
        help="Optional path for redacted bridge diagnostics. Logging is disabled by default.",
    )
    args = parser.parse_args()
    DEBUG_LOG_PATH = args.debug_log
    debug_log("--- mcp process start ---")
    debug_log(
        "parsed args:",
        f"server_name={'set' if args.server_name else 'default'}",
        f"allowed_roots={len(args.allowed_root)}",
        f"timeout={args.emacsclient_timeout:g}",
    )

    proxy = EmacsProxy(args.emacsclient, args.server_name, args.emacsclient_timeout, args.allowed_root)

    while True:
        try:
            message = read_message()
        except ProtocolError as exc:
            write_message(error_response(exc.code, exc.message, exc.request_id))
            continue
        if message is None:
            debug_log("message loop exiting: no message")
            return 0
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            write_message(error_response(-32600, "Invalid Request: params must be an object", request_id))
            continue
        debug_log("received method:", method, "id:", request_id)

        try:
            if method == "initialize":
                write_message(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "protocolVersion": PROTOCOL_VERSION,
                            "serverInfo": SERVER_INFO,
                            "capabilities": {"tools": {}},
                        },
                    }
                )
            elif method == "notifications/initialized":
                continue
            elif method == "ping":
                write_message({"jsonrpc": "2.0", "id": request_id, "result": {}})
            elif method == "tools/list":
                write_message(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {"tools": proxy.tool_catalog()},
                    }
                )
            elif method == "tools/call":
                write_message(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": handle_tool_call(
                            proxy,
                            params.get("name", ""),
                            {} if params.get("arguments") is None else params.get("arguments"),
                        ),
                    }
                )
            else:
                write_message(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {
                            "code": -32601,
                            "message": f"Method not found: {method}",
                        },
                    }
                )
        except Exception as exc:  # pragma: no cover - protocol safety net
            write_message(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": text_result(str(exc), is_error=True),
                }
            )


if __name__ == "__main__":
    raise SystemExit(main())
