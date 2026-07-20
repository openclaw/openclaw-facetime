import { describe, expect, it } from "vitest";
import {
  isActiveCall,
  isEndedCall,
  isIncomingRingingCall,
  isWhitelistedFaceTimeCall,
  normalizeFaceTimeCallEvent,
  normalizeFaceTimeHandle,
} from "../src/call-events.js";

describe("FaceTime call events", () => {
  it("normalizes helper call-status events", () => {
    const event = normalizeFaceTimeCallEvent({
      event: "ft-call-status-changed",
      data: {
        call_uuid: "call-1",
        conversation_uuid: "conversation-1",
        conversation_group_uuid: "group-1",
        conversation_audio_enabled: true,
        conversation_video_enabled: false,
        conversation_av_mode: 1,
        conversation_resolved_audio_video_mode: "1",
        call_status: 4,
        is_outgoing: false,
        is_sending_audio: true,
        is_sending_transmission: true,
        is_sending_video: false,
        is_uplink_muted: false,
        local_meter_level: "0.37",
        remote_meter_level: 0.18,
        handle: { value: "mailto:omar@example.com" },
      },
    });

    expect(event?.data.call_uuid).toBe("call-1");
    expect(event?.data.conversation_uuid).toBe("conversation-1");
    expect(event?.data.conversation_group_uuid).toBe("group-1");
    expect(event?.data.conversation_audio_enabled).toBe(true);
    expect(event?.data.conversation_video_enabled).toBe(false);
    expect(event?.data.conversation_av_mode).toBe(1);
    expect(event?.data.conversation_resolved_audio_video_mode).toBe(1);
    expect(event?.data.call_status).toBe(4);
    expect(event?.data.is_sending_audio).toBe(true);
    expect(event?.data.is_sending_transmission).toBe(true);
    expect(event?.data.is_sending_video).toBe(false);
    expect(event?.data.is_uplink_muted).toBe(false);
    expect(event?.data.local_meter_level).toBe(0.37);
    expect(event?.data.remote_meter_level).toBe(0.18);
    expect(isIncomingRingingCall(event!)).toBe(true);
    expect(isActiveCall(event!)).toBe(false);
    expect(isEndedCall(event!)).toBe(false);
  });

  it("matches whitelisted handle values case-insensitively", () => {
    const event = normalizeFaceTimeCallEvent({
      event: "ft-call-status-changed",
      data: {
        call_uuid: "call-1",
        call_status: 4,
        is_outgoing: false,
        handle: { value: "MAILTO:Omar@Example.com" },
      },
    });

    expect(normalizeFaceTimeHandle(event?.data.handle)).toBe("MAILTO:Omar@Example.com");
    expect(
      isWhitelistedFaceTimeCall({
        event: event!,
        whitelistHandles: ["omar@example.com"],
      }),
    ).toBe(true);
  });

  it("ignores country codes and searches nested handle dictionaries", () => {
    const event = normalizeFaceTimeCallEvent({
      event: "ft-call-status-changed",
      data: {
        call_uuid: "call-1",
        call_status: 1,
        is_outgoing: false,
        handle: {
          isoCountryCode: "us",
          person: {
            handle: {
              normalizedValue: "mailto:omar@example.com",
            },
          },
        },
      },
    });

    expect(normalizeFaceTimeHandle(event?.data.handle)).toBe("mailto:omar@example.com");
    expect(
      isWhitelistedFaceTimeCall({
        event: event!,
        whitelistHandles: ["omar@example.com"],
      }),
    ).toBe(true);
  });

  it("treats non-ringing/non-active statuses as ended", () => {
    const event = normalizeFaceTimeCallEvent({
      event: "ft-call-status-changed",
      data: { call_uuid: "call-1", call_status: 6 },
    });

    expect(isEndedCall(event!)).toBe(true);
  });
});
