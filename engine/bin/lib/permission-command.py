#!/usr/bin/env python3
"""Read-only guard for the removal commands in a Bash permission request.

JSON hook input arrives on stdin. A successful classification exits 0 and prints
either an unsafe-removal reason or nothing. Unparseable shell syntax exits 1 so
the caller can leave Claude Code's permission prompt to the person.

This is deliberately not a shell interpreter: quoting and nested shell commands
are inspected without executing them or expanding variables/globs. Literal
paths are checked against the Critical paths list in Claude Code's permission
modes documentation: https://code.claude.com/docs/en/permission-modes#critical-paths
Bulava also rejects *all* dynamic removal
targets, including guarded variables and globs below an otherwise safe path.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import ntpath
import os
import re
import sys


class CannotClassify(ValueError):
    """The command needs Claude Code's normal permission flow."""


@dataclass
class Word:
    value: str
    dynamic: bool = False
    tilde: bool = False
    nested: list[str] = field(default_factory=list)


OPERATORS = (";;&", "<<-", "<<<", "&&", "||", ";;", ";&", "|&", "<<",
             ">>", "<&", ">&", "<>", "&>", ">|")
REDIRECTIONS = {"<", ">", "<<", "<<-", "<<<", ">>", "<&", ">&", "<>", "&>", ">|"}
ASSIGNMENT = re.compile(r"^[a-zA-Z_][a-zA-Z_0-9]*=")
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "ash"}


def substitution(source: str, start: int, opener: str, closer: str) -> tuple[str, int]:
    """Find a balanced substitution, respecting shell quotes and escapes."""
    index, depth, quote = start, 1, ""
    begin = index
    while index < len(source):
        char = source[index]
        if char == "\\" and quote != "'":
            index += 2
            continue
        if quote == "'":
            if char == "'":
                quote = ""
        elif char == "'" and not quote:
            quote = "'"
        elif char == '"':
            quote = "" if quote == '"' else '"'
        elif source.startswith("$(", index) and quote != "'":
            _, index = substitution(source, index + 2, "(", ")")
            continue
        elif char == "`" and quote != "'":
            _, index = backticks(source, index + 1)
            continue
        elif not quote:
            if char == opener:
                depth += 1
            elif char == closer:
                depth -= 1
                if not depth:
                    return source[begin:index], index + 1
        index += 1
    raise CannotClassify("unfinished shell substitution")


def backticks(source: str, start: int) -> tuple[str, int]:
    index, parts = start, []
    while index < len(source):
        char = source[index]
        if char == "`":
            return "".join(parts), index + 1
        if char == "\\" and index + 1 < len(source) and source[index + 1] in "\\$`":
            index += 1
            char = source[index]
        parts.append(char)
        index += 1
    raise CannotClassify("unfinished backtick substitution")


def lex(source: str) -> list[Word | str]:
    """Keep literal arguments separate from active shell expansions."""
    tokens: list[Word | str] = []
    index = 0
    while index < len(source):
        char = source[index]
        if char in " \t\r":
            index += 1
            continue
        if char == "#":
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
            continue
        if char == "\n":
            tokens.append(";")
            index += 1
            continue
        if char in "{}" and (index + 1 == len(source) or source[index + 1] in " \t\r\n;()"):
            tokens.append(char)
            index += 1
            continue
        if char in ";|&()<>":
            # A process substitution is an argument, not a redirection/group.
            if not (char in "<>" and source.startswith(char + "(", index)):
                operator = next((op for op in OPERATORS if source.startswith(op, index)), char)
                if operator in {"<<", "<<-"}:
                    # Here-document bodies need their own expansion rules.
                    # Do not mistake their data for commands or approve them blind.
                    raise CannotClassify("here-document requires normal permission review")
                tokens.append(operator)
                index += len(operator)
                continue
        parts, nested, dynamic, quote, tilde = [], [], False, "", False
        started = False
        while index < len(source):
            char = source[index]
            if not quote and (char in " \t\r\n;|&()" or
                              (char in "<>" and not source.startswith(char + "(", index))):
                break
            started = True
            if char == "\\" and quote != "'":
                if index + 1 == len(source):
                    raise CannotClassify("unfinished shell escape")
                following = source[index + 1]
                if quote == '"' and following not in '$`"\\\n':
                    parts.append("\\")
                    index += 1
                    continue
                if following != "\n":
                    parts.append(following)
                index += 2
                continue
            if quote == "'":
                if char == "'":
                    quote = ""
                else:
                    parts.append(char)
                index += 1
                continue
            if char == "'" and not quote:
                quote = "'"
                index += 1
                continue
            if char == '"':
                quote = "" if quote == '"' else '"'
                index += 1
                continue
            if not quote and char == "$" and source[index:index + 2] in {"$'", '$"'}:
                raise CannotClassify("ANSI or locale quoting requires normal permission review")
            if not quote and char in "@!?*+" and source.startswith(char + "(", index):
                inner, end = substitution(source, index + 2, "(", ")")
                nested.extend(embedded_commands(inner))
                parts.append(source[index:end])
                dynamic = True
                index = end
                continue
            if source.startswith("$(", index):
                inner, end = substitution(source, index + 2, "(", ")")
                if inner.startswith("("):
                    # Arithmetic is data, but substitutions in it still execute.
                    nested.extend(embedded_commands(inner))
                else:
                    nested.append(inner)
                parts.append(source[index:end])
                dynamic = True
                index = end
                continue
            if source.startswith("${", index):
                inner, end = substitution(source, index + 2, "{", "}")
                if quote == '"' and "'" in inner and ("$(" in inner or "`" in inner):
                    # Quotes in a double-quoted parameter expression have special
                    # rules; defer instead of treating executable text as data.
                    raise CannotClassify("complex parameter expansion requires normal permission review")
                nested.extend(embedded_commands(inner))
                parts.append(source[index:end])
                dynamic = True
                index = end
                continue
            if char == "`":
                inner, end = backticks(source, index + 1)
                nested.append(inner)
                parts.append(source[index:end])
                dynamic = True
                index = end
                continue
            if not quote and char in "<>" and source.startswith(char + "(", index):
                inner, end = substitution(source, index + 2, "(", ")")
                nested.append(inner)
                parts.append(source[index:end])
                dynamic = True
                index = end
                continue
            if char == "$" and index + 1 < len(source) and re.match(r"[a-zA-Z_0-9@*#?!$-]", source[index + 1]):
                dynamic = True
            if not quote and char in "*?[":
                dynamic = True
            if not quote and char == "{" and re.match(r"\{[^{}]*?(?:,|\.\.)[^{}]*?\}", source[index:]):
                dynamic = True
            if not quote and char == "~" and not parts:
                tilde = True
            parts.append(char)
            index += 1
        if quote:
            raise CannotClassify("unfinished shell quote")
        if not started:
            raise CannotClassify("unsupported shell token")
        tokens.append(Word("".join(parts), dynamic, tilde, nested))
    return tokens


def embedded_commands(source: str) -> list[str]:
    """Find actual substitutions inside parameter/arithmetic expressions."""
    return [inner for token in lex(source) if isinstance(token, Word) for inner in token.nested]


def ancestors(path: str) -> set[str]:
    found = set()
    while path not in found:
        found.add(path)
        path = os.path.dirname(path)
    return found


class Guard:
    def __init__(self, cwd: str):
        self.cwd = os.path.abspath(cwd)
        self.home = os.path.expanduser("~")
        self.protected = ancestors(self.cwd) | ancestors(os.path.realpath(self.cwd))
        self.protected |= {self.home, os.path.realpath(self.home)}

    def target(self, word: Word, directories: set[str | None]) -> str:
        if word.dynamic:
            return "removal target uses a shell variable, substitution, or glob"
        value = word.value
        if not value:
            return ""
        if value and not value.strip("\\"):
            return "removal target is a backslash-only filesystem root"
        if re.match(r"^[a-zA-Z]:[\\/]", value):
            windows_path = ntpath.normpath(value)
            _, tail = ntpath.splitdrive(windows_path)
            if len([part for part in re.split(r"[\\/]+", tail) if part]) <= 1:
                return "removal target is a Windows drive root or top-level directory"
        if word.tilde:
            if value == "~+" or value.startswith("~+/"):
                if None in directories:
                    return "removal target depends on an unknown working directory"
                paths = [directory + value[2:] for directory in directories if directory is not None]
            elif value == "~-" or value.startswith("~-/"):
                return "removal target depends on the previous working directory"
            else:
                expanded = os.path.expanduser(value)
                if expanded == value:
                    return "removal target uses an unresolved home directory"
                paths = [expanded]
        elif os.path.isabs(value):
            paths = [value]
        else:
            if None in directories:
                return "relative removal target follows a dynamic working-directory change"
            paths = [os.path.join(directory, value) for directory in directories if directory is not None]
        protected = set(self.protected)
        for directory in directories:
            if directory is not None:
                protected |= ancestors(directory) | ancestors(os.path.realpath(directory))
        for path in paths:
            for resolved in {os.path.normpath(path), os.path.realpath(path)}:
                if not resolved.strip("/"):
                    return "removal target is the filesystem root"
                if len([part for part in resolved.split("/") if part]) == 1:
                    return "removal target is a top-level directory"
                if resolved in protected:
                    return "removal target is the home, working directory, or a working-directory parent"
        return ""

    def change_directory(self, word: Word, directories: set[str | None]) -> set[str | None]:
        if word.dynamic or (word.tilde and word.value.startswith(("~+", "~-"))):
            return directories | {None}
        value = os.path.expanduser(word.value) if word.tilde else word.value
        changed = {os.path.realpath(os.path.join(directory, value))
                   for directory in directories if directory is not None}
        # Keep both possible outcomes: cd may fail, be conditional, or run in a pipeline.
        return directories | changed if len(directories | changed) <= 32 else {None}

    def command(self, words: list[Word], directories: set[str | None], depth: int) -> tuple[str, set[str | None]]:
        for word in words:
            for inner in word.nested:
                reason = self.scan(inner, set(directories), depth + 1)
                if reason:
                    return reason, directories
        while words and (ASSIGNMENT.match(words[0].value) or words[0].value in
                         {"!", "if", "then", "elif", "else", "do", "while", "until"}):
            words = words[1:]
        if not words:
            return "", directories
        while words:
            if words[0].dynamic:
                raise CannotClassify("dynamic executable requires normal permission review")
            name = os.path.basename(words[0].value)
            if name not in {"sudo", "env", "command", "builtin", "exec", "nohup", "nice", "timeout", "time", "busybox", "toybox"}:
                break
            words = words[1:]
            while words and (words[0].value.startswith("-") or
                             (name == "env" and ASSIGNMENT.match(words[0].value))):
                option_word = words.pop(0)
                option = option_word.value
                if option == "--":
                    break
                if name == "sudo" and option == "--login":
                    directories = directories | {None}
                if name == "sudo" and option.startswith("-") and not option.startswith("--"):
                    # Required values may be attached or follow bundled flags,
                    # as in -uroot and -iu root. Login also changes directory.
                    for position, flag in enumerate(option[1:], 1):
                        if flag == "i":
                            directories = directories | {None}
                        if flag in "ughpCTrtD":
                            attached = option[position + 1:]
                            if not attached:
                                option = "-" + flag
                            elif flag == "D":
                                directories = self.change_directory(Word(attached, option_word.dynamic), directories)
                            break
                if name in {"sudo", "env"} and option.startswith("--chdir="):
                    directories = self.change_directory(Word(option.partition("=")[2], option_word.dynamic), directories)
                if name == "env" and option.startswith("-C") and len(option) > 2:
                    directories = self.change_directory(Word(option[2:], option_word.dynamic), directories)
                if name == "sudo" and option.startswith("-D") and len(option) > 2:
                    directories = self.change_directory(Word(option[2:], option_word.dynamic), directories)
                if name == "env" and (option.startswith("-S") or option == "--split-string" or option.startswith("--split-string=")):
                    raise CannotClassify("env split-string requires normal permission review")
                if option in ({"-u", "-g", "-h", "-p", "-C", "-T", "-r", "-t", "-D", "--user", "--group", "--host", "--prompt", "--chdir"}
                              if name == "sudo" else
                              {"-u", "--unset", "-C", "--chdir"} if name == "env" else
                              {"-n", "--adjustment"} if name == "nice" else
                              {"-s", "--signal", "-k", "--kill-after"} if name == "timeout" else
                              {"-a"} if name == "exec" else
                              {"-f", "--format", "-o", "--output"} if name == "time" else set()):
                    if not words:
                        raise CannotClassify("missing wrapper option argument")
                    argument = words.pop(0)
                    if option in {"-D", "-C", "--chdir"} and name in {"sudo", "env"}:
                        directories = self.change_directory(argument, directories)
            if name == "timeout" and words:
                words = words[1:]
        if not words:
            return "", directories
        if words[0].dynamic:
            raise CannotClassify("dynamic executable requires normal permission review")
        name = os.path.basename(words[0].value)
        arguments = words[1:]
        if name in {"rm", "rmdir"}:
            options = True
            before_end = arguments[:next((index for index, word in enumerate(arguments)
                                         if word.value == "--" and not word.dynamic), len(arguments))]
            parents = name == "rmdir" and any(word.value == "--parents" or
                                              (word.value.startswith("-") and not word.value.startswith("--") and "p" in word.value)
                                              for word in before_end)
            for argument in arguments:
                if options and argument.value == "--" and not argument.dynamic:
                    options = False
                    continue
                if options and argument.value.startswith("-") and argument.value != "-" and not argument.dynamic:
                    continue
                reason = self.target(argument, directories)
                if reason:
                    return reason, directories
                if parents and argument.value:
                    return "rmdir --parents can remove a critical parent directory", directories
            return "", directories
        if name in {"cd", "pushd"}:
            arguments = [word for word in arguments if word.value not in {"--", "-L", "-P"}]
            if len(arguments) > 1:
                return "", directories | {None}
            target = arguments[0] if arguments else Word(self.home)
            if target.value == "-" or (name == "pushd" and (not arguments or re.match(r"^[+-]\d+$", target.value))):
                return "", directories | {None}
            return "", self.change_directory(target, directories)
        if name == "popd":
            return "", directories | {None}
        if name in SHELLS:
            for index, argument in enumerate(arguments):
                if argument.value.startswith("-") and "c" in argument.value[1:] and not argument.value.startswith("--"):
                    if index + 1 >= len(arguments):
                        raise CannotClassify("shell -c has no script")
                    script = arguments[index + 1]
                    reason = self.scan(script.value, set(directories), depth + 1)
                    if reason:
                        return reason, directories
                    if script.dynamic:
                        raise CannotClassify("expanded shell script requires normal permission review")
                    return "", directories
        if name == "eval":
            reason, evaluated_directories = self.script(" ".join(word.value for word in arguments), set(directories), depth + 1)
            if reason:
                return reason, directories
            if any(word.dynamic for word in arguments):
                raise CannotClassify("expanded eval requires normal permission review")
            return "", evaluated_directories
        if name in {"source", "."}:
            if any(word.dynamic for word in arguments):
                raise CannotClassify("dynamic sourced script requires normal permission review")
            return "", directories | {None}
        if name == "find":
            for index, argument in enumerate(arguments):
                if argument.value not in {"-exec", "-execdir", "-ok", "-okdir"}:
                    continue
                end = next((end for end in range(index + 1, len(arguments))
                            if arguments[end].value in {";", "+"}), len(arguments))
                nested = [Word(word.value, word.dynamic or "{}" in word.value, word.tilde)
                          for word in arguments[index + 1:end]]
                nested_cwd = {None} if argument.value.endswith("dir") else set(directories)
                reason, _ = self.command(nested, nested_cwd, depth + 1)
                if reason:
                    return reason, directories
        if name == "xargs":
            index = 0
            while index < len(arguments) and arguments[index].value.startswith("-"):
                option = arguments[index].value
                index += 1
                if option == "--":
                    break
                if option in {"-E", "-I", "-L", "-n", "-P", "-s", "-a", "-d", "--arg-file", "--delimiter", "--process-slot-var", "--eof", "--replace", "--max-lines", "--max-args", "--max-procs", "--max-chars"}:
                    index += 1
            nested = arguments[index:]
            if nested:
                # xargs appends targets obtained from stdin; they are never exact literals.
                reason, _ = self.command(nested + [Word("xargs input", dynamic=True)], set(directories), depth + 1)
                if reason:
                    return reason, directories
        return "", directories

    def scan(self, source: str, directories: set[str | None], depth: int = 0) -> str:
        return self.script(source, directories, depth)[0]

    def script(self, source: str, directories: set[str | None], depth: int = 0) -> tuple[str, set[str | None]]:
        if depth > 24:
            raise CannotClassify("shell nesting exceeds the classification limit")
        tokens = lex(source)
        words: list[Word] = []
        stack: list[tuple[str, set[str | None]]] = []
        index = 0
        while index <= len(tokens):
            token = tokens[index] if index < len(tokens) else ";"
            if isinstance(token, Word):
                # A numeric descriptor immediately before a redirect is not an argument.
                if (token.value.isdigit() and index + 1 < len(tokens) and
                        isinstance(tokens[index + 1], str) and tokens[index + 1] in REDIRECTIONS):
                    index += 1
                    continue
                words.append(token)
            elif token in REDIRECTIONS:
                if index + 1 >= len(tokens) or not isinstance(tokens[index + 1], Word):
                    raise CannotClassify("missing redirection target")
                for inner in tokens[index + 1].nested:
                    reason = self.scan(inner, set(directories), depth + 1)
                    if reason:
                        return reason, directories
                index += 1
            else:
                reason, directories = self.command(words, directories, depth)
                if reason:
                    return reason, directories
                words = []
                if token in {"(", "{"}:
                    stack.append((token, set(directories)))
                elif token in {")", "}"}:
                    if stack:
                        opener, previous = stack.pop()
                        if (opener, token) not in {("(", ")"), ("{", "}")}:
                            raise CannotClassify("unbalanced shell group")
                        if opener == "(":
                            directories = previous
                    elif token == "}":
                        raise CannotClassify("unbalanced shell group")
                    # A closing ')' may also delimit a case pattern/function name.
            index += 1
        if stack:
            raise CannotClassify("unfinished shell group")
        return "", directories


def main() -> int:
    try:
        request = json.load(sys.stdin)
        command = request.get("tool_input", {}).get("command")
        cwd = request.get("cwd")
        if not isinstance(command, str) or not isinstance(cwd, str) or not cwd or "\0" in command + cwd:
            raise CannotClassify("missing or invalid Bash command/cwd")
        reason = Guard(cwd).scan(command, {os.path.abspath(cwd)})
        if reason:
            print(reason)
        return 0
    except (CannotClassify, ValueError, TypeError, AttributeError, OSError, RecursionError):
        return 1


if __name__ == "__main__":
    sys.exit(main())
