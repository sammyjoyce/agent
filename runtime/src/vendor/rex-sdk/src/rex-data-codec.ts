/**
 * Byte layouts of the data connection handshake.
 *
 * Integers are unsigned little-endian. HELLO is `0x01` and a 16-byte ticket; RESUME is `0x02`, a
 * 16-byte reconnect token, and a u64 count of stream bytes received. The server answers with
 * WELCOME (`0x81`, token, 3 zero bytes, u32 retention in ms, u64 nonce; 32 bytes) or REJECT
 * (`0x82` and a reason byte).
 *
 * @since 0.1.0
 */
import { Option } from "effect";

/**
 * The server's answer to a HELLO or RESUME.
 *
 * @category models
 * @since 0.1.0
 */
export type RexDataHandshakeReply =
  | {
      readonly _tag: "Welcome";
      /** Token to send in a RESUME to continue this stream on a new connection. */
      readonly reconnectToken: Uint8Array;
      /** How long the server keeps the stream for a resume, in milliseconds. */
      readonly retentionMillis: number;
      /** Marks Rex's own control sequences in the terminal stream; never zero. */
      readonly nonce: bigint;
    }
  | { readonly _tag: "Reject"; readonly reason: number };

/**
 * Builds a HELLO from a `data.connect` ticket (22 base64url characters).
 *
 * @returns The 17-byte HELLO, or `None` when the ticket isn't 16 bytes of base64url.
 * @category constructors
 * @since 0.1.0
 */
export function encodeRexDataHello(ticket: string): Option.Option<Uint8Array> {
  if (!/^[A-Za-z0-9_-]{22}$/.test(ticket)) return Option.none();
  const bytes = Buffer.from(ticket, "base64url");
  if (bytes.length !== 16) return Option.none();
  const hello = new Uint8Array(17);
  hello[0] = 0x01;
  hello.set(bytes, 1);
  return Option.some(hello);
}

/**
 * Builds a RESUME from the latest reconnect token and the count of stream bytes received.
 *
 * @category constructors
 * @since 0.1.0
 */
export function encodeRexDataResume(reconnectToken: Uint8Array, receivedBytes: bigint): Uint8Array {
  const resume = Buffer.alloc(25);
  resume[0] = 0x02;
  Buffer.from(reconnectToken).copy(resume, 1, 0, 16);
  resume.writeBigUInt64LE(receivedBytes, 17);
  return new Uint8Array(resume);
}

/**
 * Parses the server's WELCOME or REJECT.
 *
 * @returns The reply, or `None` for a message that is neither.
 * @category constructors
 * @since 0.1.0
 */
export function decodeRexDataHandshakeReply(
  message: Uint8Array,
): Option.Option<RexDataHandshakeReply> {
  if (message[0] === 0x82 && message.length >= 2) {
    return Option.some({ _tag: "Reject", reason: message[1] ?? 0 });
  }
  if (message[0] !== 0x81 || message.length !== 32) return Option.none();
  const bytes = Buffer.from(message);
  const nonce = bytes.readBigUInt64LE(24);
  if (nonce === 0n) return Option.none();
  return Option.some({
    _tag: "Welcome",
    reconnectToken: new Uint8Array(bytes.subarray(1, 17)),
    retentionMillis: bytes.readUInt32LE(20),
    nonce,
  });
}
