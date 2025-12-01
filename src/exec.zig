const c = @import("c.zig").c;
const std = @import("std");

/// Fork and exec a command, detaching it from the parent process
///
/// This function uses the classic "double fork" technique to create a true daemon process
/// that is completely detached from the parent. This prevents:
/// 1. The child from becoming a zombie when it exits
/// 2. The child from being affected by terminal hangups
/// 3. Terminal output from child processes appearing in skhd's logs
///
/// References:
/// - W. Richard Stevens, "Advanced Programming in the UNIX Environment", Chapter 13: Daemon Processes
/// - Linux daemon(3) man page implementation
/// - systemd source code: src/basic/process-util.c
///
/// The double fork works as follows:
/// 1. First fork: Parent creates child1
/// 2. Child1 calls setsid() to become session leader in new session
/// 3. Second fork: Child1 creates child2
/// 4. Child1 exits immediately, child2 continues
/// 5. Parent waits for child1 to prevent zombie
/// 6. Child2 is now orphaned and adopted by init (PID 1)
/// 7. When child2 eventually exits, init automatically reaps it
pub inline fn forkAndExec(shell: [:0]const u8, command: [:0]const u8, verbose: bool) !void {
    const cpid = c.fork();
    if (cpid == -1) {
        return error.ForkFailed;
    }

    if (cpid == 0) {
        // Child process
        // Create new session (detach from controlling terminal)
        _ = c.setsid();

        // Double fork to ensure we can't reacquire a controlling terminal
        const cpid2 = c.fork();
        if (cpid2 == -1) {
            std.process.exit(1);
        }
        if (cpid2 > 0) {
            // First child exits
            std.process.exit(0);
        }

        // Second child continues
        if (!verbose) {
            const devnull = c.open("/dev/null", c.O_WRONLY);
            if (devnull != -1) {
                _ = c.dup2(devnull, 1); // stdout
                _ = c.dup2(devnull, 2); // stderr
                _ = c.close(devnull);
            }
        }

        // Prepare arguments for execvp
        // No allocation needed - strings are already null-terminated
        const arg_c = "-c";
        const argv = [_:null]?[*:0]const u8{ shell.ptr, arg_c, command.ptr, null };

        const status_code = c.execvp(shell.ptr, @ptrCast(&argv));
        // If execvp returns, it failed
        std.process.exit(@intCast(status_code));
    }

    // Parent waits for first child to exit
    // This prevents the first child from becoming a zombie and ensures
    // the double fork completes before we return. The wait is very brief
    // since child1 exits immediately after forking child2.
    var status: c_int = 0;
    _ = c.waitpid(cpid, &status, 0);
}
