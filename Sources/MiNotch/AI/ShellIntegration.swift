import Foundation

/// Señales del shell local; el silencio en stdout nunca equivale a terminar un comando.
struct ShellCommandState: Equatable {
    enum Phase: Equatable { case starting, ready, running, awaitingInput, unavailable }
    var phase = Phase.starting
    var lastExitCode: Int?
    var completedCommands = 0

    mutating func receive(_ payload: String, token: String) {
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0] == token else { return }
        switch fields[1] {
        case "start":
            phase = .running
            lastExitCode = nil
        case "ready":
            guard fields.count == 3, let code = Int(fields[2]), (0...255).contains(code) else { return }
            if phase == .running { completedCommands += 1; lastExitCode = code }
            phase = .ready
        default: break
        }
    }

    var summary: String {
        switch phase {
        case .starting: "Iniciando shell"
        case .ready:
            lastExitCode.map { "Comando terminado · código \($0)" } ?? "Terminal lista"
        case .running: "Comando en ejecución; todavía no terminó"
        case .awaitingInput: "Entrada enviada; esperando confirmación del shell"
        case .unavailable: "Estado del comando desconocido (sin señales del shell)"
        }
    }
}

/// Configuración temporal de zsh que conserva los archivos del usuario sin modificarlos.
/// Se restaura ZDOTDIR antes del primer prompt y los shells hijos arrancan normalmente.
final class ShellIntegration {
    static let oscCode = 6973
    let token = UUID().uuidString
    let directory: URL

    init(environment: inout [String: String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("minotch-zsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        do {
            for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                var script = ""
                if name == ".zshenv" {
                    script += """
                    typeset -g _minotch_wrapper="$ZDOTDIR"
                    if [[ "$MINOTCH_HAD_ZDOTDIR" == 1 ]]; then
                        export ZDOTDIR="$MINOTCH_USER_ZDOTDIR"
                    else
                        unset ZDOTDIR
                    fi
                    unset MINOTCH_HAD_ZDOTDIR MINOTCH_USER_ZDOTDIR

                    """
                } else {
                    script += "if [[ $_minotch_had_zdotdir == 1 ]]; then export ZDOTDIR=\"$_minotch_user_zdotdir\"; else unset ZDOTDIR; fi\n"
                }
                script += "[[ -r ${ZDOTDIR:-$HOME}/\(name) ]] && source \"${ZDOTDIR:-$HOME}/\(name)\"\n"
                if name == ".zlogin" {
                    script += Self.hooks(token: token)
                    script += "\nunset _minotch_wrapper _minotch_user_zdotdir _minotch_had_zdotdir\n"
                } else {
                    script += """
                    typeset -g _minotch_had_zdotdir=${+ZDOTDIR}
                    typeset -g _minotch_user_zdotdir=${ZDOTDIR-}
                    export ZDOTDIR="$_minotch_wrapper"

                    """
                }
                try script.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        environment["MINOTCH_HAD_ZDOTDIR"] = environment["ZDOTDIR"] == nil ? "0" : "1"
        environment["MINOTCH_USER_ZDOTDIR"] = environment["ZDOTDIR"] ?? ""
        environment["ZDOTDIR"] = directory.path
    }

    static func hooks(token: String) -> String {
        // El token es un UUID generado por la app, nunca entrada del usuario.
        """
        _minotch_b64() { builtin printf '%s' "$1" | command base64 | command tr -d '\\n' }
        _minotch_preexec() {
            # Comando y carpeta en base64: nunca interpretan nada del lado de la app.
            builtin printf '\\e]\(oscCode);\(token);start;%s;%s\\a' "$(_minotch_b64 "$1")" "$(_minotch_b64 "$PWD")"
            return 0
        }
        _minotch_precmd() {
            local minotch_exit=$?
            builtin printf '\\e]\(oscCode);\(token);ready;%d\\a' "$minotch_exit"
            builtin printf '\\e]\(oscCode);\(token);cwd;%s\\a' "$(_minotch_b64 "$PWD")"
            return 0
        }
        # La app dibuja su propio prompt (carpeta, rama): el del shell se oculta. Va al final para ganarle a
        # cualquier tema (powerlevel10k, oh-my-zsh…) que arme PROMPT en su precmd.
        _minotch_prompt_off() {
            PROMPT=''
            RPROMPT=''
            PROMPT_EOL_MARK=''
            return 0
        }
        typeset -ga preexec_functions precmd_functions
        preexec_functions=(_minotch_preexec ${preexec_functions:#_minotch_preexec})
        precmd_functions=(_minotch_precmd ${precmd_functions:#(_minotch_precmd|_minotch_prompt_off)} _minotch_prompt_off)
        unsetopt PROMPT_SP
        _minotch_prompt_off
        """
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
