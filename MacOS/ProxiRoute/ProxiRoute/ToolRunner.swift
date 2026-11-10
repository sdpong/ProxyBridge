import Foundation

// Running a tool of the system and holding its answer.
//
// The file handle of Foundation does not close its descriptor when it is let
// go of, so a pipe that is left alone keeps its two descriptors for ever.
// The app is a program that stays up for days and asks the system questions
// all the time, and the helper of the gateway mode asks the kernel every few
// seconds. A program that runs out of descriptors cannot open a file: the
// helper would stop being able to write the rules of the gateway, and the
// gateway mode would stop working without saying a word.
//
// Every pipe of a tool is closed here, in one place, so that no call site can
// forget it.
//
// This file is used by the app and by the helper of the gateway mode. The
// helper is a program of root and it runs for days as well, and it is the one
// that runs out of descriptors the fastest.
enum ToolRunner {

    // Which of the two outputs of the tool is kept.
    //
    // The two of them cannot be read one after the other: a tool that fills
    // the pipe of one of them while the other one is full waits for ever. So
    // one of them is asked for at a time.
    enum Capture {
        /// the ordinary output
        case output
        /// the error output
        case error
        /// both of them, in one pipe
        case both
    }

    // What a tool said, and whether it worked.
    //
    // The exit code of pfctl is 0 even when the filter refused what it was
    // given: it says the reason on the error output and returns 0 all the
    // same. So the text is kept as well, and the reason is read from it.
    struct Answer {
        /// the exit code of the tool, or -1 when it could not be started
        let status: Int32
        /// what the tool said, in the part that was kept
        let text: String

        /// whether the tool ran and was happy
        var succeeded: Bool { status == 0 }
    }

    // Closes a file handle, and does not care whether it worked.
    //
    // The close of a file handle of Foundation can fail, and there is
    // nothing to be done about it here: the handle is let go of either way.
    // A handle that is closed twice is a handle that raises, so it is closed
    // once and only once - by the one that owns it.
    static func close(_ handle: FileHandle) {
        try? handle.close()
    }

    // Runs a tool and gives back what it said.
    //
    // The tool is run with its full path, because the helper runs with a
    // small PATH and the paths of the tools are known.
    //
    // Nothing is given back when the tool could not be started at all.
    static func run(_ path: String,
                    _ arguments: [String],
                    capture: Capture = .both) -> Answer? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // A tool that waits for input would wait for ever, and the input of
        // the helper is the console of nobody.
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        switch capture {
        case .output:
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        case .error:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = pipe
        case .both:
            // One pipe for the two of them: the tool cannot block on a pipe
            // that nobody reads.
            process.standardOutput = pipe
            process.standardError = pipe
        }

        do {
            try process.run()
        } catch {
            close(pipe.fileHandleForReading)
            close(pipe.fileHandleForWriting)
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // The two ends of the pipe are closed here.
        //
        // The file handle of Foundation does not close its descriptor when it
        // is let go of, so a pipe that is left alone keeps its two
        // descriptors for ever. The app asks the helper what the machine
        // looks like every few seconds, and every question runs two tools -
        // so the helper would run out of descriptors within the hour, and a
        // helper that cannot open a file cannot write the rules of the
        // gateway. The gateway mode would stop working, and the window would
        // say that the file of the rules could not be saved.
        close(pipe.fileHandleForReading)
        close(pipe.fileHandleForWriting)

        return Answer(status: process.terminationStatus,
                      text: String(data: data, encoding: .utf8) ?? "")
    }
}
