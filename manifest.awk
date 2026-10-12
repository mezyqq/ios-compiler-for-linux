# Makefile generator for big multi-module projects (ipab MANIFEST mode).
#
# Input: a TSV manifest, one library per line:
#   1 kind (swift_library|objc_library|cc_library)  2 label  3 module_name  4 srcs  5 hdrs  6 deps
#   7 copts  8 includes  9 defines  10 sdk_frameworks  11 sdk_dylibs  12 enable_modules  13 data
#   14 textual_hdrs  15 cxxopts  16 weak_sdk_frameworks  17 linkopts  18 package
# Paths: "pkg/file" (in SRCROOT), "@ext/<repo>/file" (EXT), "@gen/..." (GEN). Lists are space separated.
#
# Variables (-v): SRCROOT EXT GEN B SWIFTC TCRES SDK MINIOS CACHE OPTC OPTS SWIFT_THREADS ROOTS OUT RTOBJ LDID ENT LDFLAGS AR
#
# Output: Makefile on stdout (run with `make -C $SRCROOT`), plus module maps and output file maps under $B.
#   - ObjC / C / C++ files compile one object per source (-MMD header deps), never depend on Swift.
#   - A Swift module compiles in one swiftc call (-wmo, -num-threads), after the Swift modules and
#     the ObjC module maps it imports.
#   - Everything reachable from ROOTS is linked into $OUT.

BEGIN {
    FS = "\t"
    n = 0
}

{
    # undo the escaping of jq @tsv (\\ -> \), e.g. -DNAME=\"value\" in copts
    for (f = 1; f <= NF; f++) gsub(/\\\\/, "\\", $f)
    n++
    label = $2
    idx[label] = n
    L[n] = label
    kind[n] = $1
    modname[n] = $3
    srcs[n] = $4
    hdrs[n] = $5
    deps[n] = $6
    copts[n] = $7
    incs[n] = $8
    defs[n] = $9
    fws[n] = $10
    dylibs[n] = $11
    modules[n] = $12
    txthdrs[n] = $14
    cxxopts[n] = $15
    weakfws[n] = $16
    linkopts[n] = $17
    pkg[n] = $18
}

function rp(p) {
    if (substr(p, 1, 5) == "@gen/") return GEN "/" substr(p, 6)
    if (substr(p, 1, 5) == "@ext/") return EXT "/" substr(p, 6)
    return SRCROOT "/" p
}

function sanitize(s,    r) {
    r = s
    gsub(/[^A-Za-z0-9_]/, "_", r)
    return r
}

# Directory of a package in the source tree / in the generated tree.
function pkgdir(i, gen,    lab, repo, p) {
    lab = L[i]
    p = pkg[i]
    if (substr(lab, 1, 1) == "@") {
        repo = lab
        sub(/^@@?/, "", repo)
        sub(/\/\/.*$/, "", repo)
        return (gen ? GEN "/@ext/" : EXT "/") repo (p == "" ? "" : "/" p)
    }
    return (gen ? GEN : SRCROOT) (p == "" ? "" : "/" p)
}

# Transitive dependencies (indices) as a space separated string, memoized.
function closure(i,    a, m, k, d, j, r, seen, out, parts, c, q) {
    if (i in tdeps) return tdeps[i]
    tdeps[i] = ""
    out = ""
    delete seen
    m = split(deps[i], a, " ")
    for (k = 1; k <= m; k++) {
        if (!(a[k] in idx)) continue
        d = idx[a[k]]
        if (!(d in seen)) { seen[d] = 1; out = out " " d }
        r = closure(d)
        c = split(r, parts, " ")
        for (q = 1; q <= c; q++) if (!(parts[q] in seen)) { seen[parts[q]] = 1; out = out " " parts[q] }
    }
    tdeps[i] = out
    return out
}

function isswift(i) { return kind[i] == "swift_library" }
function iscfam(i) { return kind[i] == "objc_library" || kind[i] == "cc_library" }

# -I flags contributed by a C-family library (its `includes`, in source and generated trees).
function incflags(i,    a, m, k, d, out) {
    out = ""
    m = split(incs[i], a, " ")
    for (k = 1; k <= m; k++) {
        d = a[k]
        if (d == ".") d = ""
        out = out " -I" pkgdir(i, 0) (d == "" ? "" : "/" d) " -I" pkgdir(i, 1) (d == "" ? "" : "/" d)
    }
    return out
}

function defflags(i,    a, m, k, out) {
    out = ""
    m = split(defs[i], a, " ")
    for (k = 1; k <= m; k++) out = out " -D" a[k]
    return out
}

# Drops options that only make sense for Bazel or that turn this compiler's new warnings into errors.
function cleancopts(s,    a, m, k, out) {
    out = ""
    m = split(s, a, " ")
    for (k = 1; k <= m; k++) {
        if (a[k] == "-warnings-as-errors" || a[k] == "-Werror") continue
        out = out " " a[k]
    }
    return out
}

function modmap(i) { return B "/modulemaps/" modname[i] ".modulemap" }

function writemodmap(i,    f, a, m, k) {
    f = modmap(i)
    printf "module \"%s\" {\n    export *\n", modname[i] > f
    m = split(hdrs[i], a, " ")
    for (k = 1; k <= m; k++) if (a[k] ~ /\.(h|hh|hpp)$/) printf "    header \"%s\"\n", rp(a[k]) > f
    m = split(txthdrs[i], a, " ")
    for (k = 1; k <= m; k++) printf "    textual header \"%s\"\n", rp(a[k]) > f
    print "}" > f
    close(f)
}

END {
    # --- what to build: everything reachable from ROOTS
    m = split(ROOTS, r, " ")
    for (k = 1; k <= m; k++) {
        if (!(r[k] in idx)) { print "manifest.awk: no root " r[k] > "/dev/stderr"; exit 1 }
        i = idx[r[k]]
        want[i] = 1
        c = split(closure(i), parts, " ")
        for (q = 1; q <= c; q++) want[parts[q]] = 1
    }

    system("mkdir -p " B "/modulemaps " B "/swift " B "/link")

    for (i = 1; i <= n; i++) {
        if (!(i in want)) continue
        if (kind[i] == "objc_library" && modname[i] != "" && hdrs[i] != "") { hasmap[i] = 1; writemodmap(i) }
    }

    print ".SUFFIXES:"
    print "OBJ :="
    print "all: " OUT
    print ""

    linklist = ""
    swiftstamps = ""
    for (i = 1; i <= n; i++) {
        if (!(i in want)) continue
        id = sanitize(L[i])
        td = closure(i)
        c = split(td, tparts, " ")

        # Context from dependencies: include dirs, defines, module maps (C family only).
        ctx = ""
        maps = ""
        mapfiles = ""
        for (q = 1; q <= c; q++) {
            d = tparts[q]
            if (!iscfam(d)) continue
            ctx = ctx incflags(d) defflags(d)
            if (d in hasmap) { maps = maps " -fmodule-map-file=" modmap(d); mapfiles = mapfiles " " modmap(d) }
        }

        if (iscfam(i)) {
            base = "-target arm64-apple-ios" MINIOS " -isysroot " SDK " " OPTC " -iquote " SRCROOT " -iquote " GEN " -MMD -MP"
            own = incflags(i) defflags(i) ctx
            objc = kind[i] == "objc_library"
            mods = ""
            # Module maps of dependencies are for Swift only: C-family code includes their headers
            # textually (building a module from every header of a C++ library fails).
            if (objc && modules[i] == "1") mods = " -fmodules -fmodules-cache-path=" CACHE "/clang"
            co = cleancopts(copts[i])
            cxo = cleancopts(cxxopts[i])
            libobjs = ""
            ms = split(srcs[i], sa, " ")
            for (k = 1; k <= ms; k++) {
                s = sa[k]
                if (s ~ /\.a$/) { linklist = linklist " " rp(s); continue }
                if (s !~ /\.(c|m|mm|cc|cpp|cxx|S|s)$/) continue
                src = rp(s)
                o = B "/o/" id "/" s ".o"
                gsub(/@/, "_", o)
                lang = ""
                cc = "clang"
                if (s ~ /\.c$/) lang = ""
                else if (s ~ /\.m$/) lang = objc ? " -fobjc-arc" : ""
                else if (s ~ /\.mm$/) { cc = "clang++"; lang = " -std=c++17" (objc ? " -fobjc-arc" : "") }
                else if (s ~ /\.(S|s)$/) lang = ""
                else { cc = "clang++"; lang = " -std=c++17" }
                extra = (cc == "clang++") ? cxo : ""
                print o ": " src " " B "/cflags.stamp"
                print "\t@echo '  CC     " s "'"
                print "\t@mkdir -p $(dir $@)"
                print "\t@" cc " " base lang mods own " " co extra " -c " src " -o $@"
                print "-include " substr(o, 1, length(o) - 2) ".d"
                linklist = linklist " " o
                libobjs = libobjs " " o
            }
            # Static archive of this library alone (what Bazel's $(location <cc_library>) gives genrules).
            print B "/libs/" id ".a:" libobjs
            print "\t@mkdir -p $(dir $@) && rm -f $@ && " AR " rcs $@" libobjs
            for (q = 1; q <= split(fws[i], fa, " "); q++) frameworks[fa[q]] = 1
            for (q = 1; q <= split(weakfws[i], fa, " "); q++) weakframeworks[fa[q]] = 1
            for (q = 1; q <= split(dylibs[i], fa, " "); q++) libs[fa[q]] = 1
            linkflags = linkflags " " linkopts[i]
        } else if (isswift(i)) {
            mname = modname[i] != "" ? modname[i] : sanitize(substr(L[i], index(L[i], ":") + 1))
            stamp = B "/swift/" id ".stamp"
            ofm = B "/swift/" id ".json"
            dir = B "/so/" id
            srclist = ""
            objlist = ""
            depfiles = ""
            printf "{\"\":{\"swift-dependencies\":\"%s/master.swiftdeps\"}", dir > ofm
            ms = split(srcs[i], sa, " ")
            for (k = 1; k <= ms; k++) {
                if (sa[k] !~ /\.swift$/) continue
                src = rp(sa[k])
                o = dir "/" k ".o"
                printf ",\n\"%s\":{\"object\":\"%s\"}", src, o > ofm
                srclist = srclist " " src
                objlist = objlist " " o
                linklist = linklist " " o
            }
            print "}" > ofm
            close(ofm)
            if (srclist == "") continue
            for (q = 1; q <= c; q++) {
                d = tparts[q]
                if (isswift(d)) depfiles = depfiles " " B "/swift/" sanitize(L[d]) ".stamp"
            }
            # Clang options for the imported C-family modules.
            xcc = ""
            nx = split(ctx maps " -iquote " SRCROOT " -iquote " GEN, xa, " ")
            for (q = 1; q <= nx; q++) if (xa[q] != "") xcc = xcc " -Xcc " xa[q]
            print stamp ":" srclist " " B "/swflags.stamp" depfiles mapfiles
            print "\t@echo '  SWIFT  " mname "'"
            print "\t@mkdir -p " dir " " B "/mods"
            print "\t@" SWIFTC " -c -parse-as-library -module-name " mname " -emit-module-path " B "/mods/" mname ".swiftmodule" \
                  " -output-file-map " ofm " " OPTS " -wmo -num-threads " SWIFT_THREADS \
                  " -sdk " SDK " -target arm64-apple-ios" MINIOS " -resource-dir " TCRES \
                  " -module-cache-path " CACHE "/swift -runtime-compatibility-version none -I " B "/mods" \
                  cleancopts(copts[i]) xcc srclist
            print "\t@touch $@"
            # The objects are produced by the module's swiftc call.
            print substr(objlist, 2) ": " stamp " ;"
            swiftstamps = swiftstamps " " stamp
            if (srclist != "") hasswift = 1
        }
    }

    # --- link
    rsp = B "/link/objects.rsp"
    nl = split(linklist, la, " ")
    printf "" > rsp
    for (k = 1; k <= nl; k++) print la[k] > rsp
    close(rsp)
    fl = ""
    for (f in frameworks) fl = fl " -framework " f
    for (f in weakframeworks) fl = fl " -weak_framework " f
    for (f in libs) fl = fl " -l" f
    print "OBJECTS :=" linklist
    print OUT ": $(OBJECTS)" swiftstamps " " RTOBJ " " B "/ldflags.stamp"
    print "\t@echo '  LD     " OUT "'"
    print "\t@clang++ -target arm64-apple-ios" MINIOS " -isysroot " SDK " -fuse-ld=lld @" rsp " " RTOBJ \
          " -L" SDK "/usr/lib/swift -Wl,-rpath,/usr/lib/swift -Wl,-rpath,@executable_path/Frameworks" \
          " -ObjC" fl " " linkflags " " LDFLAGS " -o $@"
    if (LDID != "") print "\t@" LDID " -S" ENT " $@"
}
