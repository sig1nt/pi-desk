# Transcript `scrollTo` layout loop

## Summary

PiDesk could appear to freeze while an agent was streaming even though the underlying `pi --mode rpc` process was still working. The failure was in the transcript UI: geometry observation and programmatic scrolling formed a positive feedback loop that kept the SwiftUI main thread busy.

The vulnerable implementation was in `Conversation` in `Sources/PiDesk/PiDeskApp.swift`. It measured the frame of the complete transcript with a `GeometryReader` and `TranscriptFrameKey`; `onPreferenceChange` then called `ScrollViewProxy.scrollTo` when the measured height changed.

The fix is implemented using separate scalar content-height and bottom-marker preferences, deferred measurement reconciliation, and a coalesced 30 Hz follow scroll. This document records the incident and the design constraints that prevent regressions.

## Symptoms

- The transcript stops visibly updating while the agent is working.
- Buttons and scrolling become unresponsive.
- PiDesk consumes approximately one CPU core continuously.
- The child Pi process remains alive, and its session JSONL file continues to grow.
- Restarting PiDesk restores responsiveness until another sufficiently busy or long stream triggers the problem.

This is a UI stall, not necessarily an agent, provider, network, or RPC stall. Before terminating Pi, check the child process and session file so useful work is not interrupted.

## Observed incident

During the original incident:

- PiDesk was pinned at 100% CPU.
- The Pi child was alive and continued to edit files and run tests.
- The session contained 249 messages, including several large tool results.
- A process sample placed the main thread in SwiftUI `AttributeGraph`, `LazySubviewPlacements`, and `LazyStack.place` work.
- The sample also included `Conversation.body` around the transcript geometry reader and `TranscriptFrameKey.reduce`.

Large histories make the failure easier to trigger, but they are an amplifier rather than the root cause.

## Root cause

The current flow is effectively:

1. A streamed token, thinking update, tool result, image, or disclosure changes transcript layout.
2. The transcript `GeometryReader` publishes a new frame preference.
3. `onPreferenceChange` updates local `@State` and calls `scrollTo("bottom")` while follow-bottom is enabled.
4. `scrollTo` changes the scroll view's geometry and schedules another SwiftUI layout pass.
5. The geometry preference is evaluated again, causing more state writes and potentially another scroll.
6. Streaming supplies more invalidations before the main thread settles.

The implementation publishes a full `CGRect`, even though content height and viewport position have different meanings. It also writes `transcriptHeight` and `viewportHeight` on every preference callback. This couples three operations that must be independent:

- detecting whether the user is near the bottom;
- detecting that content changed size;
- moving the scroll position.

`LazyVStack` does not prevent the problem. Measuring and repeatedly positioning a long stack still performs substantial layout work, especially when rows contain selectable Markdown, nested scroll views, or large tool results.

RPC output is delivered to `SessionController` on the main queue. Once layout monopolizes that queue, incoming records cannot be rendered promptly, which makes the healthy agent look frozen.

## Required fix

Break the feedback edge from **scroll-position geometry** directly to **synchronous `scrollTo`**.

The fixed design should have these properties:

1. **Separate measurements.** Observe only the bottom marker's viewport position to determine whether the user is near the bottom. If content-size observation is needed, publish only a scalar height—not a frame whose origin changes during scrolling.
2. **Avoid no-op state writes.** Assign `@State` only when the value actually changes beyond a small tolerance.
3. **Never scroll synchronously from a geometry preference callback.** Record the new state and schedule a coalesced scroll for a later run-loop turn or frame.
4. **Coalesce streaming updates.** At most one follow-bottom scroll should be pending. A 30–60 Hz cap is sufficient; one scroll per token is not.
5. **Preserve user intent.** If the user scrolls away from the bottom, cancel a pending follow scroll and do not resume until they use the jump-to-latest button or submit a new message.
6. **Keep measurement acyclic.** Programmatic scrolling may change the bottom marker's viewport position, but it must not change the content-size signal that requests another scroll.

### Recommended structure

Use two narrow preference values:

```swift
private struct TranscriptContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TranscriptBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
```

The bottom marker reports its `maxY` in the named viewport coordinate space. That signal only updates whether the user is near the bottom:

```swift
.onPreferenceChange(TranscriptBottomKey.self) { bottomY in
    let nearBottom = bottomY <= viewportHeight + 60
    if nearBottom != isNearBottom {
        isNearBottom = nearBottom
    }
}
```

Content-height changes may request a follow scroll, but only for a real size change and only while follow-bottom intent is active:

```swift
.onPreferenceChange(TranscriptContentHeightKey.self) { height in
    guard abs(height - transcriptHeight) > 1 else { return }
    let grew = height > transcriptHeight
    transcriptHeight = height
    if grew && followBottom {
        scheduleFollowScroll(proxy)
    }
}
```

`scheduleFollowScroll` must defer and coalesce the operation:

```swift
private func scheduleFollowScroll(_ proxy: ScrollViewProxy) {
    guard followBottom, !followScrollScheduled else { return }
    followScrollScheduled = true

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) {
        followScrollScheduled = false
        guard followBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}
```

The snippets show the separation of responsibilities; they are not a drop-in patch. State names and user-scroll detection should be integrated with `Conversation` as one coherent change.

### Safer minimal mitigation

If a complete implementation is not ready, remove the transcript-frame preference and restore explicit, coalesced triggers based on message count and active-message content. This may not follow every image or disclosure resize, but it is preferable to a main-thread livelock. The jump-to-latest button provides a fallback.

Do not retain the existing full-frame callback merely with a longer tolerance. That reduces the frequency but leaves the feedback cycle intact.

## Validation

Test the fix with a release and debug build. A short conversation is not sufficient.

1. Open a saved session with at least 200 messages and large tool results.
2. Stream a long answer containing both thinking and text.
3. Stream partial tool output, then complete the tool call.
4. Expand and collapse tool and thinking disclosure groups while following the bottom.
5. Render an image whose decoded thumbnail changes row height.
6. Scroll upward during generation and verify the view does not pull itself back down.
7. Use jump-to-latest and verify following resumes.
8. Submit a new message while scrolled up and verify the documented product behavior.
9. Sample PiDesk during streaming. Main-thread layout work may spike briefly, but CPU must return below a full core and the UI must remain interactive.
10. Confirm RPC events continue to appear without a growing visual delay.

Useful diagnostics:

```sh
ps -p <pidesk-pid> -o pid,%cpu,time,state,command
sample <pidesk-pid> 3 1 -file /tmp/pidesk-sample.txt
stat -f '%Sm %z' /path/to/session.jsonl
```

A successful fix should not show nearly every main-thread sample inside a continuous SwiftUI layout transaction.

## Regression guardrails

- Geometry preference callbacks must not directly call `scrollTo`.
- Do not publish a full transcript `CGRect` when only height is needed.
- Do not perform unconditional `@State` writes from preference callbacks.
- Keep one pending programmatic follow scroll at most.
- Treat transcript size and tool-output limits as separate performance work; truncation alone is not a fix for the feedback loop.
