#define _GNU_SOURCE

#include <errno.h>
#include <libaudit.h>
#include <sys/capability.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <syslog.h>

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef AGENT_COMMAND
#error "AGENT_COMMAND must name the fixed agent launcher"
#endif

#ifndef AGENT_AUDIT_LOGIN_UID
#define AGENT_AUDIT_LOGIN_UID 4294967294U
#endif

static void warn_message(const char *message)
{
    fprintf(stderr, "agent: process audit degraded: %s\n", message);
    openlog("agent-process-label", LOG_PID, LOG_AUTHPRIV);
    syslog(LOG_WARNING, "%s", message);
    closelog();
}

static char *read_one_line(const char *path)
{
    FILE *stream;
    char *line = NULL;
    size_t size = 0;
    ssize_t length;

    stream = fopen(path, "re");
    if (stream == NULL)
        return NULL;
    length = getline(&line, &size, stream);
    fclose(stream);
    if (length < 0) {
        free(line);
        return NULL;
    }
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r'))
        line[--length] = '\0';
    return line;
}

static char *hex_encode(const unsigned char *input)
{
    static const char digits[] = "0123456789abcdef";
    size_t length = strlen((const char *)input);
    char *output;
    size_t index;

    if (length > (SIZE_MAX - 1) / 2)
        return NULL;
    output = malloc(length * 2 + 1);
    if (output == NULL)
        return NULL;
    for (index = 0; index < length; ++index) {
        output[index * 2] = digits[input[index] >> 4];
        output[index * 2 + 1] = digits[input[index] & 0x0f];
    }
    output[length * 2] = '\0';
    return output;
}

static int write_launch_marker(uid_t original_auid, uid_t current_auid,
    int labeled)
{
    char cwd[PATH_MAX];
    char hostname[HOST_NAME_MAX + 1];
    char *boot_id;
    char *cwd_hex;
    char *hostname_hex;
    char *message;
    int audit_fd;
    int result;
    int needed;

    if (getcwd(cwd, sizeof(cwd)) == NULL)
        strcpy(cwd, "");
    if (gethostname(hostname, sizeof(hostname)) != 0)
        strcpy(hostname, "unknown");
    hostname[sizeof(hostname) - 1] = '\0';
    boot_id = read_one_line("/proc/sys/kernel/random/boot_id");
    if (boot_id == NULL)
        boot_id = strdup("unknown");
    cwd_hex = hex_encode((const unsigned char *)cwd);
    hostname_hex = hex_encode((const unsigned char *)hostname);
    if (boot_id == NULL || cwd_hex == NULL || hostname_hex == NULL) {
        free(boot_id);
        free(cwd_hex);
        free(hostname_hex);
        errno = ENOMEM;
        return -1;
    }

    needed = snprintf(NULL, 0,
        "agent_process_launch schema=1 boot_id=%s root_pid=%ld ruid=%lu rgid=%lu "
        "original_auid=%lu audit_auid=%u label=%s host_hex=%s cwd_hex=%s",
        boot_id, (long)getpid(), (unsigned long)getuid(), (unsigned long)getgid(),
        (unsigned long)original_auid, (unsigned int)current_auid,
        labeled ? "labeled" : "degraded", hostname_hex, cwd_hex);
    if (needed < 0) {
        free(boot_id);
        free(cwd_hex);
        free(hostname_hex);
        return -1;
    }
    message = malloc((size_t)needed + 1);
    if (message == NULL) {
        free(boot_id);
        free(cwd_hex);
        free(hostname_hex);
        return -1;
    }
    snprintf(message, (size_t)needed + 1,
        "agent_process_launch schema=1 boot_id=%s root_pid=%ld ruid=%lu rgid=%lu "
        "original_auid=%lu audit_auid=%u label=%s host_hex=%s cwd_hex=%s",
        boot_id, (long)getpid(), (unsigned long)getuid(), (unsigned long)getgid(),
        (unsigned long)original_auid, (unsigned int)current_auid,
        labeled ? "labeled" : "degraded", hostname_hex, cwd_hex);

    audit_fd = audit_open();
    if (audit_fd < 0) {
        result = -1;
    } else {
        result = audit_log_user_message(audit_fd, AUDIT_USER, message,
            hostname, NULL, NULL, labeled ? 1 : 0);
        audit_close(audit_fd);
    }
    free(message);
    free(boot_id);
    free(cwd_hex);
    free(hostname_hex);
    return result < 0 ? -1 : 0;
}

static int clear_capabilities(void)
{
    cap_t empty;
    int result = 0;

    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0 &&
        errno != EINVAL)
        result = -1;
    empty = cap_init();
    if (empty == NULL)
        return -1;
    if (cap_set_proc(empty) != 0)
        result = -1;
    cap_free(empty);
    return result;
}

int main(int argc, char **argv)
{
    uid_t original_auid;
    uid_t current_auid;
    char pid_text[32];
    char **agent_argv;
    int labeled;
    int marker_written;
    int index;

    original_auid = audit_getloginuid();
    labeled = audit_setloginuid((uid_t)AGENT_AUDIT_LOGIN_UID) == 0;
    current_auid = audit_getloginuid();
    marker_written =
        write_launch_marker(original_auid, current_auid, labeled) == 0;

    snprintf(pid_text, sizeof(pid_text), "%ld", (long)getpid());
    if (setenv("AGENT_PROCESS_LABEL_PID", pid_text, 1) != 0 ||
        setenv("AGENT_PROCESS_LABEL_STATUS", labeled ? "labeled" : "degraded", 1) != 0) {
        warn_message("could not prepare the labeled launcher environment");
    }
    if (!labeled)
        warn_message("could not assign the agent audit identity; argv capture is disabled");
    if (!marker_written)
        warn_message("could not write the agent launch marker");
    if (clear_capabilities() != 0) {
        warn_message("could not clear all helper capabilities");
        return 126;
    }

    agent_argv = calloc((size_t)argc + 1, sizeof(*agent_argv));
    if (agent_argv == NULL) {
        warn_message("could not allocate the launcher argument vector");
        return 126;
    }
    agent_argv[0] = (char *)AGENT_COMMAND;
    for (index = 1; index < argc; ++index)
        agent_argv[index] = argv[index];
    agent_argv[argc] = NULL;

    execv(AGENT_COMMAND, agent_argv);
    warn_message("could not execute the fixed agent launcher");
    return errno == ENOENT ? 127 : 126;
}
