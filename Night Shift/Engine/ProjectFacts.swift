import Foundation

nonisolated enum ProjectFacts {

    static func gitContext(projectPath: String, commits: Int = 12) async -> String {
        let cwd = URL(fileURLWithPath: projectPath)

        let script = """
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 3
        printf 'BRANCH: '; git rev-parse --abbrev-ref HEAD 2>/dev/null
        printf 'UPSTREAM: '; git rev-parse --abbrev-ref '@{u}' 2>/dev/null || printf '(none)\\n'
        echo
        echo "RECENT COMMITS (newest first, with the parts of the tree each one touched):"
        # Directories, not file lists: one localisation commit touches forty .strings files and would
        # eat the whole budget, while "did this touch the macOS app or only the server?" is answered
        # by the directory alone.
        git log -n "$1" --date=short --pretty=format:'%h %ad %s' --dirstat=files,0,3 2>/dev/null | head -c 4000
        echo
        echo
        echo "UNCOMMITTED RIGHT NOW:"
        git status --porcelain=v1 2>/dev/null | head -40
        echo
        echo "BRANCHES TOUCHED IN THE LAST WEEK:"
        git for-each-ref --sort=-committerdate --count=12 \
            --format='%(refname:short)  %(committerdate:short)  %(subject)' refs/heads 2>/dev/null
        """
        let r = await Shell.run(script, args: [String(commits)], cwd: cwd, timeout: 25)
        guard r.launched, r.exitCode == 0 else { return "" }
        let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return """
        <git-facts source="bulava ran git in this repository; you cannot run git yourself">
        \(text)
        </git-facts>
        """
    }

    static func lookPrompt(question: String, gitContext: String) -> String {
        var out = ""
        if !gitContext.isEmpty { out += gitContext + "\n\n" }
        out += """
        The director is asking about this project. Answer HIM — in his language, in a few sentences,
        no headings and no plan. Ground every claim in something you actually read: cite file:line for
        code, and the commit for anything about history. If the answer is not in this repository, say
        so plainly instead of inferring it.

        \(question)
        """
        return out
    }
}
