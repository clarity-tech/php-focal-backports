<?php
// Print the API surface of PHP's own extensions, one fact per line, sorted, so two builds can be
// compared with diff. Run with the CLI on a production host to make a baseline
// (targets/<target>-php<branch>.parity), and by scripts/test.sh on the rebuild.
//
// Names only for functions, classes, methods and constants: those depend on which libraries PHP
// was compiled against (libzip, libgd, pcre2, libxml2...), which is what this catches. Values only
// where a library version is compiled in. Extensions that PHP's own source does not build (mongodb, redis,
// igbinary, msgpack, opentelemetry) are skipped, so a host's extra modules do not count.
$skip = ['mongodb', 'redis', 'igbinary', 'msgpack', 'opentelemetry'];
$out = [];
foreach (get_loaded_extensions() as $ext) {
    if (in_array(strtolower($ext), $skip, true)) continue;
    $e = new ReflectionExtension($ext);
    $out[] = "ext $ext";
    foreach ($e->getFunctions() as $f) $out[] = "fn $ext " . $f->getName();
    // STDIN/STDOUT/STDERR exist only when the CLI runs a script file, not one piped on stdin (as
    // the production baseline was taken over SSM), so they say nothing about the build.
    foreach (array_keys($e->getConstants()) as $c) if (!in_array($c, ['STDIN', 'STDOUT', 'STDERR'], true)) $out[] = "const $ext $c";
    foreach ($e->getClasses() as $cl) {
        $out[] = "class $ext " . $cl->getName();
        foreach ($cl->getMethods() as $m) $out[] = "method $ext " . $cl->getName() . '::' . $m->getName();
        foreach (array_keys($cl->getConstants()) as $c) $out[] = "classconst $ext " . $cl->getName() . "::$c";
    }
}
if (function_exists('gd_info')) foreach (gd_info() as $k => $v) $out[] = "gd_info $k=" . var_export($v, true);
if (class_exists('ZipArchive')) $out[] = 'value ZipArchive::LIBZIP_VERSION=' . ZipArchive::LIBZIP_VERSION;
if (defined('LIBXML_VERSION')) $out[] = 'value LIBXML_VERSION=' . LIBXML_VERSION;
if (defined('PCRE_VERSION_MAJOR')) $out[] = 'value PCRE_VERSION_MAJOR.MINOR=' . PCRE_VERSION_MAJOR . '.' . PCRE_VERSION_MINOR;
// pcre2 >= 10.38 rejects \K inside a lookaround unless PHP sets PCRE2_EXTRA_ALLOW_LOOKAROUND_BSK,
// which it does only when compiled against pcre2 >= 10.38 headers.
$out[] = 'behaviour pcre \K in lookahead=' . var_export(@preg_match('/(?=a\K)/', 'a'), true);
sort($out);
echo implode("\n", array_unique($out)), "\n";
