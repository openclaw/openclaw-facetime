export type FaceTimeCallStatusEvent = {
  event: "ft-call-status-changed";
  data: FaceTimeCallStatusData;
};

export type FaceTimeCallStatusData = {
  audio_mode?: unknown;
  call_status?: unknown;
  call_uuid?: unknown;
  conversation_group_uuid?: unknown;
  conversation_uuid?: unknown;
  conversation_audio_enabled?: unknown;
  conversation_video_enabled?: unknown;
  conversation_av_mode?: unknown;
  conversation_resolved_audio_video_mode?: unknown;
  disconnected_reason?: unknown;
  ended_error?: unknown;
  ended_reason?: unknown;
  handle?: unknown;
  is_conversation?: unknown;
  is_outgoing?: unknown;
  is_sending_audio?: unknown;
  is_sending_transmission?: unknown;
  is_sending_video?: unknown;
  is_uplink_muted?: unknown;
  local_meter_level?: unknown;
  remote_meter_level?: unknown;
};

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function readFiniteNumber(value: unknown): number | undefined {
  const number =
    typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(number) ? number : undefined;
}

const handleValueKeys = new Set([
  "address",
  "email",
  "emailAddress",
  "handle",
  "normalizedValue",
  "phoneNumber",
  "unformattedPhoneNumber",
  "value",
]);

function collectHandleCandidates(
  value: unknown,
  candidates: string[] = [],
  seen = new Set<unknown>(),
): string[] {
  const direct = readString(value);
  if (direct) {
    candidates.push(direct);
    return candidates;
  }
  if (!value || typeof value !== "object" || seen.has(value)) {
    return candidates;
  }
  seen.add(value);
  const record = asRecord(value);
  for (const [key, nested] of Object.entries(record)) {
    if (handleValueKeys.has(key)) {
      collectHandleCandidates(nested, candidates, seen);
    } else if (nested && typeof nested === "object") {
      collectHandleCandidates(nested, candidates, seen);
    }
  }
  return candidates;
}

export function normalizeFaceTimeHandleCandidates(value: unknown): string[] {
  return [...new Set(collectHandleCandidates(value).map((candidate) => candidate.trim()))];
}

export function normalizeFaceTimeHandle(value: unknown): string | undefined {
  return normalizeFaceTimeHandleCandidates(value)[0];
}

function canonicalizeHandle(value: string): string {
  const stripped = value
    .trim()
    .toLowerCase()
    .replace(/^mailto:/, "")
    .replace(/^tel:/, "")
    .replace(/^facetime-audio:/, "")
    .replace(/^facetime:/, "");
  return stripped.includes("@") ? stripped : stripped.replace(/[^\d+]/g, "");
}

export function normalizeFaceTimeCallEvent(value: unknown): FaceTimeCallStatusEvent | undefined {
  const record = asRecord(value);
  if (record.event !== "ft-call-status-changed") {
    return undefined;
  }
  const data = asRecord(record.data);
  const callUUID = readString(data.call_uuid);
  const conversationUUID = readString(data.conversation_uuid);
  const conversationGroupUUID = readString(data.conversation_group_uuid);
  const conversationAVMode =
    typeof data.conversation_av_mode === "number"
      ? data.conversation_av_mode
      : typeof data.conversation_av_mode === "string"
        ? Number(data.conversation_av_mode)
        : undefined;
  const conversationResolvedAVMode =
    typeof data.conversation_resolved_audio_video_mode === "number"
      ? data.conversation_resolved_audio_video_mode
      : typeof data.conversation_resolved_audio_video_mode === "string"
        ? Number(data.conversation_resolved_audio_video_mode)
        : undefined;
  const status =
    typeof data.call_status === "number"
      ? data.call_status
      : typeof data.call_status === "string"
        ? Number(data.call_status)
        : undefined;
  if (!callUUID || !Number.isInteger(status)) {
    return undefined;
  }
  return {
    event: "ft-call-status-changed",
    data: {
      ...data,
      call_uuid: callUUID,
      call_status: status,
      conversation_uuid: conversationUUID,
      conversation_group_uuid: conversationGroupUUID,
      conversation_audio_enabled: data.conversation_audio_enabled === true,
      conversation_video_enabled: data.conversation_video_enabled === true,
      conversation_av_mode: Number.isInteger(conversationAVMode) ? conversationAVMode : undefined,
      conversation_resolved_audio_video_mode: Number.isInteger(conversationResolvedAVMode)
        ? conversationResolvedAVMode
        : undefined,
      is_outgoing: data.is_outgoing === true,
      is_sending_audio: data.is_sending_audio === true,
      is_sending_transmission: data.is_sending_transmission === true,
      is_sending_video: data.is_sending_video === true,
      is_uplink_muted: data.is_uplink_muted === true,
      local_meter_level: readFiniteNumber(data.local_meter_level),
      remote_meter_level: readFiniteNumber(data.remote_meter_level),
    },
  };
}

export function isWhitelistedFaceTimeCall(params: {
  event: FaceTimeCallStatusEvent;
  whitelistHandles: readonly string[];
}): boolean {
  const handles = normalizeFaceTimeHandleCandidates(params.event.data.handle);
  if (handles.length === 0) {
    return false;
  }
  const canonicalHandles = new Set(handles.map(canonicalizeHandle));
  return params.whitelistHandles.some((entry) => {
    const canonicalEntry = canonicalizeHandle(entry);
    return canonicalHandles.has(canonicalEntry);
  });
}

export function isIncomingRingingCall(event: FaceTimeCallStatusEvent): boolean {
  return event.data.call_status === 4 && event.data.is_outgoing !== true;
}

export function isActiveCall(event: FaceTimeCallStatusEvent): boolean {
  return event.data.call_status === 1;
}

export function isEndedCall(event: FaceTimeCallStatusEvent): boolean {
  return !isIncomingRingingCall(event) && !isActiveCall(event);
}
