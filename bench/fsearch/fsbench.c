// Local benchmark harness (not part of FSearch): builds a database for ROOT
// and times searches through the public async API, from queuing the search
// work to the "search-finished" signal.
//
// stdin: one case per line, "<flags>\t<query>"  (flags: a=all, d=folders, f=files)
// stdout: TSV  case_query  flags  first_ms  median_ms  cpu_ms  folders  files
#include "fsearch_database.h"
#include "fsearch_database_exclude.h"
#include "fsearch_database_exclude_manager.h"
#include "fsearch_database_include.h"
#include "fsearch_database_include_manager.h"
#include "fsearch_database_search_info.h"
#include "fsearch_database_work.h"
#include "fsearch_filter_manager.h"
#include "fsearch_query.h"
#include <gio/gio.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

typedef struct {
    GMainLoop *loop;
    guint folders, files;
} Ctx;

static void
on_search_finished(FsearchDatabase *db, guint id, FsearchDatabaseSearchInfo *info, gpointer user_data) {
    Ctx *ctx = user_data;
    if (info) {
        ctx->folders = fsearch_database_search_info_get_num_folders(info);
        ctx->files = fsearch_database_search_info_get_num_files(info);
    }
    g_main_loop_quit(ctx->loop);
}

static double
cpu_ms(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000.0 + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1000.0;
}

static long
rss_kib(void) {
    FILE *f = fopen("/proc/self/status", "r");
    char line[256];
    long v = 0;
    while (f && fgets(line, sizeof line, f)) {
        if (strncmp(line, "VmRSS:", 6) == 0) v = strtol(line + 6, NULL, 10);
    }
    if (f) fclose(f);
    return v;
}

static int
cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int
main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: fsbench ROOT DBFILE REPEATS [monitor]\n");
        return 2;
    }
    const char *root = argv[1];
    int repeats = atoi(argv[3]);
    gboolean monitor = argc > 4;
    const char *excludes[] = {".git", "node_modules", ".cache", "__pycache__", ".npm", ".nvm", ".cargo",
                              ".rustup", ".gradle", ".venv", "venv", NULL};
    const char *anchored[] = {".local/share/Trash", ".local/share/flatpak", NULL};

    g_autoptr(FsearchDatabaseIncludeManager) im = fsearch_database_include_manager_new();
    g_autoptr(FsearchDatabaseInclude) inc = fsearch_database_include_new(root, TRUE, FALSE, monitor, FALSE, 0);
    fsearch_database_include_manager_add(im, inc);
    g_autoptr(FsearchDatabaseExcludeManager) em = fsearch_database_exclude_manager_new();
    fsearch_database_exclude_manager_set_exclude_hidden(em, FALSE);
    for (int i = 0; excludes[i]; i++) {
        g_autoptr(FsearchDatabaseExclude) e = fsearch_database_exclude_new(excludes[i], TRUE,
            FSEARCH_DATABASE_EXCLUDE_TYPE_FIXED, FSEARCH_DATABASE_EXCLUDE_MATCH_SCOPE_BASENAME,
            FSEARCH_DATABASE_EXCLUDE_TARGET_BOTH);
        fsearch_database_exclude_manager_add(em, e);
    }
    for (int i = 0; anchored[i]; i++) {
        g_autofree char *full = g_build_filename(root, anchored[i], NULL);
        g_autoptr(FsearchDatabaseExclude) e = fsearch_database_exclude_new(full, TRUE,
            FSEARCH_DATABASE_EXCLUDE_TYPE_FIXED, FSEARCH_DATABASE_EXCLUDE_MATCH_SCOPE_FULL_PATH,
            FSEARCH_DATABASE_EXCLUDE_TARGET_BOTH);
        fsearch_database_exclude_manager_add(em, e);
    }

    long rss0 = rss_kib();
    GFile *dbfile = g_file_new_for_path(argv[2]);
    FsearchDatabase *db = fsearch_database_new(dbfile, im, em);
    gint64 t0 = g_get_monotonic_time();
    double c0 = cpu_ms();
    if (fsearch_database_rescan_blocking(db) != FSEARCH_RESULT_SUCCESS) {
        fprintf(stderr, "rescan failed\n");
        return 1;
    }
    fprintf(stderr, "build_ms=%.1f build_cpu_ms=%.1f rss_kib=%ld rss_delta_kib=%ld\n",
            (g_get_monotonic_time() - t0) / 1000.0, cpu_ms() - c0, rss_kib(), rss_kib() - rss0);

    FsearchFilterManager *filters = fsearch_filter_manager_new_with_defaults();
    Ctx ctx = {0};
    g_signal_connect(db, "search-finished", G_CALLBACK(on_search_finished), &ctx);
    char line[16384];
    guint view = 1;
    double *t = g_new(double, repeats + 1);
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = 0;
        const char *kind = line, *text = tab + 1;
        FsearchQueryFlags flags = QUERY_FLAG_AUTO_MATCH_CASE | QUERY_FLAG_AUTO_SEARCH_IN_PATH;
        if (kind[0] == 'd') flags |= QUERY_FLAG_FOLDERS_ONLY;
        if (kind[0] == 'f') flags |= QUERY_FLAG_FILES_ONLY;
        double c1 = cpu_ms();
        for (int r = 0; r <= repeats; r++) {
            g_autoptr(FsearchQuery) q = fsearch_query_new(text, NULL, filters, flags, "bench");
            g_autoptr(FsearchDatabaseWork) w =
                fsearch_database_work_new_search(view, q, DATABASE_INDEX_PROPERTY_NAME, GTK_SORT_ASCENDING);
            ctx.loop = g_main_loop_new(NULL, FALSE);
            gint64 s = g_get_monotonic_time();
            fsearch_database_queue_work(db, w);
            g_main_loop_run(ctx.loop);
            t[r] = (g_get_monotonic_time() - s) / 1000.0;
            g_main_loop_unref(ctx.loop);
        }
        double cpu = (cpu_ms() - c1) / (repeats + 1);
        double first = t[0];
        qsort(t + 1, repeats, sizeof(double), cmp_double);
        printf("%s\t%s\t%.3f\t%.3f\t%.2f\t%u\t%u\n", kind, text, first, t[1 + repeats / 2], cpu, ctx.folders, ctx.files);
        fflush(stdout);
    }
    fprintf(stderr, "final_rss_kib=%ld\n", rss_kib());
    _exit(0); // skip the final save-to-file on dispose; not part of the measurement
}
