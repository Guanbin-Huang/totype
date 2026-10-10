import Foundation

@main
struct CompletionDeadlineTest {
    static func main() async {
        let quick = Task<Int, Never> { 42 }
        let quickResult = await CompletionDeadline.wait(
            for: quick,
            timeoutNanoseconds: 1_000_000_000,
            onTimeout: { quick.cancel() }
        )
        guard case .completed(42) = quickResult else {
            fputs("FAIL: 快速任务被错误判为超时\n", stderr)
            exit(1)
        }

        let hanging = Task<Int, Never> {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {}
            return 7
        }
        let started = Date()
        let timeoutResult = await CompletionDeadline.wait(
            for: hanging,
            timeoutNanoseconds: 80_000_000,
            onTimeout: {
                hanging.cancel()
                // WebSocket cancellation can itself take time. The caller's
                // deadline must not wait for cleanup to return.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        )
        let elapsed = Date().timeIntervalSince(started)
        guard case .timedOut = timeoutResult, elapsed < 0.75 else {
            fputs("FAIL: 超时结果仍被慢清理阻塞\n", stderr)
            exit(1)
        }

        let observedProvider = Task<Int, Never> {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                return 99
            } catch { return -1 }
        }
        let softResult = await CompletionDeadline.wait(
            for: observedProvider,
            timeoutNanoseconds: 10_000_000,
            cancelTaskOnTimeout: false,
            onTimeout: {}
        )
        guard case .timedOut = softResult else { fatalError("soft observation did not time out") }
        let laterValue = await observedProvider.value
        guard !observedProvider.isCancelled, laterValue == 99 else {
            fatalError("soft observation cancelled the original provider")
        }
        guard hanging.isCancelled, !quick.isCancelled else {
            fatalError("hard cancellation/completed-task semantics changed")
        }
        print("completion deadline checks passed; soft observation preserves provider; hard deadline cancels")
    }
}
