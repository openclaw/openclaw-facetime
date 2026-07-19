import { randomUUID } from "node:crypto";
import net from "node:net";
import type { RuntimeLogger } from "openclaw/plugin-sdk/plugin-runtime";
import { formatErrorMessage } from "./errors.js";

type HelperSocketServerParams = {
  host: string;
  port: number;
  logger: RuntimeLogger;
  onMessage: (message: unknown) => void;
  onDisconnect?: () => void;
};

export type HelperActionResult = Record<string, unknown>;

type PendingRpc = {
  resolve: (result: HelperActionResult) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

export class FaceTimeHelperSocketServer {
  readonly #server: net.Server;
  readonly #sockets = new Set<net.Socket>();
  readonly #pending = new Map<string, PendingRpc>();
  readonly #logger: RuntimeLogger;
  #started = false;

  constructor(private readonly params: HelperSocketServerParams) {
    this.#logger = params.logger;
    this.#server = net.createServer((socket) => this.#handleSocket(socket));
  }

  async start(): Promise<void> {
    if (this.#started) {
      return;
    }
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => {
        this.#server.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        this.#server.off("error", onError);
        this.#started = true;
        resolve();
      };
      this.#server.once("error", onError);
      this.#server.once("listening", onListening);
      this.#server.listen(this.params.port, this.params.host);
    });
  }

  async stop(): Promise<void> {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("helper socket server stopped"));
    }
    this.#pending.clear();
    for (const socket of this.#sockets) {
      socket.destroy();
    }
    this.#sockets.clear();
    if (!this.#started) {
      return;
    }
    await new Promise<void>((resolve) => {
      this.#server.close(() => resolve());
    });
    this.#started = false;
  }

  async answerCall(callUUID: string): Promise<HelperActionResult> {
    return await this.#sendAction("answer-call", { callUUID });
  }

  async leaveCall(callUUID: string): Promise<HelperActionResult> {
    return await this.#sendAction("leave-call", { callUUID });
  }

  async safetyMute(callUUID: string): Promise<HelperActionResult> {
    return await this.#sendActionToAll("safety-mute", { callUUID });
  }

  async setMuted(callUUID: string, muted: boolean): Promise<HelperActionResult> {
    return await this.#sendActionToAll("set-muted", { callUUID, muted });
  }

  async startTransmission(callUUID: string): Promise<HelperActionResult> {
    return await this.#sendActionToAll("start-transmission", { callUUID });
  }

  get connectedSockets(): number {
    return this.#sockets.size;
  }

  #handleSocket(socket: net.Socket): void {
    this.#sockets.add(socket);
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      while (true) {
        const newline = buffer.search(/\r?\n/);
        if (newline < 0) {
          break;
        }
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(buffer[newline] === "\r" ? newline + 2 : newline + 1);
        if (line) {
          this.#handleLine(line);
        }
      }
    });
    socket.on("error", (error) => {
      this.#logger.debug?.(`[facetime] helper socket error: ${formatErrorMessage(error)}`);
    });
    socket.on("close", () => {
      this.#sockets.delete(socket);
      if (this.#sockets.size === 0) {
        this.params.onDisconnect?.();
      }
    });
  }

  #handleLine(line: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      this.#logger.debug?.(`[facetime] ignored invalid helper JSON: ${formatErrorMessage(error)}`);
      return;
    }
    const record = parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
    const transactionId = typeof record.transactionId === "string" ? record.transactionId : "";
    if (transactionId && this.#pending.has(transactionId)) {
      const pending = this.#pending.get(transactionId);
      this.#pending.delete(transactionId);
      if (pending) {
        clearTimeout(pending.timeout);
        if (typeof record.error === "string" && record.error) {
          pending.reject(new Error(record.error));
        } else {
          pending.resolve(record);
        }
      }
      return;
    }
    this.params.onMessage(parsed);
  }

  async #sendAction(
    action: string,
    data: Record<string, unknown>,
  ): Promise<HelperActionResult> {
    const socket = [...this.#sockets].find((candidate) => !candidate.destroyed);
    if (!socket) {
      throw new Error("FaceTime helper is not connected to the facetime event socket");
    }
    const transactionId = randomUUID();
    const payload = JSON.stringify({ action, data, transactionId });
    return await new Promise<HelperActionResult>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#pending.delete(transactionId);
        reject(new Error(`FaceTime helper action timed out: ${action}`));
      }, 5_000);
      this.#pending.set(transactionId, { resolve, reject, timeout });
      socket.write(`${payload}\r\n`, (error) => {
        if (!error) {
          return;
        }
        clearTimeout(timeout);
        this.#pending.delete(transactionId);
        reject(error);
      });
    });
  }

  async #sendActionToAll(
    action: string,
    data: Record<string, unknown>,
  ): Promise<HelperActionResult> {
    const sockets = [...this.#sockets].filter((candidate) => !candidate.destroyed);
    if (sockets.length === 0) {
      throw new Error("FaceTime helper is not connected to the facetime event socket");
    }
    const results = await Promise.allSettled(
      sockets.map((socket) => this.#sendActionOnSocket(socket, action, data)),
    );
    const fulfilled = results
      .filter((result): result is PromiseFulfilledResult<HelperActionResult> => result.status === "fulfilled")
      .map((result) => result.value);
    if (fulfilled.length > 0) {
      return {
        helpersContacted: sockets.length,
        helperResults: fulfilled,
        ...fulfilled[fulfilled.length - 1],
      };
    }
    const firstRejected = results.find(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    throw firstRejected?.reason instanceof Error
      ? firstRejected.reason
      : new Error(`FaceTime helper action failed: ${action}`);
  }

  async #sendActionOnSocket(
    socket: net.Socket,
    action: string,
    data: Record<string, unknown>,
  ): Promise<HelperActionResult> {
    const transactionId = randomUUID();
    const payload = JSON.stringify({ action, data, transactionId });
    return await new Promise<HelperActionResult>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#pending.delete(transactionId);
        reject(new Error(`FaceTime helper action timed out: ${action}`));
      }, 5_000);
      this.#pending.set(transactionId, { resolve, reject, timeout });
      socket.write(`${payload}\r\n`, (error) => {
        if (!error) {
          return;
        }
        clearTimeout(timeout);
        this.#pending.delete(transactionId);
        reject(error);
      });
    });
  }
}
