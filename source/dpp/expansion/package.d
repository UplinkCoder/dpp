/**
   Deals with expanding #include directives inline.
 */
module dpp.expansion;


import dpp.from;


/**
   Params:
       translUnitFileName = The file name with all #include directives to parse
       context = The translation context
       language = Whether it's a C or C++ file
       includePaths = The list of files to pass as -I options to clang
 */
void expand(in string translUnitFileName,
            ref from!"dpp.runtime.context".Context context,
            in string[] includePaths,
            in string file = __FILE__,
            in size_t line = __LINE__)
    @safe
{
    import dpp.translation.translation: translateTopLevelCursor;
    import dpp.runtime.context: Language;
    import clang: Cursor;

    const extern_ = context.language == Language.Cpp ? "extern(C++)" : "extern(C)";
    context.writeln([extern_, "{"]);

    auto translationUnit = parseTU(translUnitFileName, context, includePaths);
    auto cursors = canonicalCursors(translationUnit);

    foreach(cursor; cursors) {

        if(context.hasSeen(cursor)) continue;
        context.rememberCursor(cursor);

        const indentation = context.indentation;
        const lines = translateTopLevelCursor(cursor, context, file, line);
        if(lines.length) context.writeln(lines);
        context.setIndentation(indentation);
    }

    context.writeln(["}", ""]);
    context.writeln("");
}


private from!"clang".TranslationUnit parseTU
    (
        in string translUnitFileName,
        ref from!"dpp.runtime.context".Context context,
        in string[] includePaths,
    )
    @safe
{
    import dpp.runtime.context: Language;
    import clang: parse, TranslationUnitFlags;
    import std.array: array;
    import std.algorithm: map;

    auto parseArgs =
        includePaths.map!(a => "-I" ~ a).array ~
        context.options.defines.map!(a => "-D" ~ a).array
        ;

    if(context.options.parseAsCpp || context.language == Language.Cpp)
        parseArgs ~= ["-xc++", "-std=c++14"];
    else
        parseArgs ~= "-xc";

    return parse(translUnitFileName,
                 parseArgs,
                 TranslationUnitFlags.DetailedPreprocessingRecord);
}


/**
   In C there can be several declarations and one definition of a type.
   In D we can have only ever one of either. There might be multiple
   cursors in the translation unit that all refer to the same canonical type.
   Unfortunately, the canonical type is orthogonal to which cursor is the actual
   definition, so we prefer to find the definition if it exists, and if not, we
   take the canonical declaration so as to not repeat ourselves in D.
*/
from!"clang".Cursor[] canonicalCursors(from!"clang".TranslationUnit translationUnit) @safe {
    // translationUnit isn't const becaus the cursors need to be sorted

    import clang: Cursor;
    import std.algorithm: filter, partition;
    import std.range: chain;
    import std.array: array;

    auto topLevelCursors = translationUnit.cursor.children;
    return canonicalCursors(topLevelCursors);
}


/**
   In C there can be several declarations and one definition of a type.
   In D we can have only ever one of either. There might be multiple
   cursors in the translation unit that all refer to the same canonical type.
   Unfortunately, the canonical type is orthogonal to which cursor is the actual
   definition, so we prefer to find the definition if it exists, and if not, we
   take the canonical declaration so as to not repeat ourselves in D.
*/
from!"clang".Cursor[] canonicalCursors(R)(R cursors) @safe {
    import clang: Cursor;
    import std.algorithm: filter, partition;
    import std.range: chain;
    import std.array: array;

    auto leafCursors = cursors.filter!(c => c.kind != Cursor.Kind.Namespace);
    auto nsCursors = cursors.filter!(c => c.kind == Cursor.Kind.Namespace);

    auto ret =
        chain(trueLeafCursors(leafCursors), trueNsCursors(nsCursors))
        .array;

    // put the macros at the end
    ret.partition!(a => a.kind != Cursor.Kind.MacroDefinition);

    return ret;
}


// Given an arbitrary range of cursors, returns a new range filtering out
// the "ghosts" (useless repeated cursors).
// Only works when there are no namespaces
from!"clang".Cursor[] trueLeafCursors(R)(R cursors) @trusted /* who knows */ {

    import std.algorithm: chunkBy, fold, map, sort;
    import std.array: array;

    return
        cursors
        // each chunk is a range of cursors with the same name
        .array  // needed by sort
        .sort!((a, b) => a.canonical.sourceRange.start <
                         b.canonical.sourceRange.start)
        // each chunk is a range of cursors representing the same canonical entity
        .chunkBy!((a, b) => a.canonical == b.canonical)
        // for each chunk, extract the one cursor we want

        .map!(chunk => chunk.fold!mergeLeaves)
        .array
        ;
}


// merges namespace cursors together
from!"clang".Cursor[] trueNsCursors(R)(R cursors) @trusted /* who knows */ {

    import std.algorithm: chunkBy, fold, map, sort;
    import std.array: array;

    auto ret =
        cursors
        .array // needed by sort
        .sort!((a, b) => a.spelling < b.spelling)
        // each chunk is a range of NS cursors with the same name
        .chunkBy!((a, b) => a.spelling == b.spelling)
        .map!(chunk => chunk.fold!mergeNodes)
        .array
        ;

    // if there's only one namespace, the fold above does nothing,
    // so we make the children cursors canonical here
    if(ret.length == 1) {
        ret[0].children = canonicalCursors(ret[0].children);
    }

    return ret;
}

from!"clang".Cursor mergeCursors(from!"clang".Cursor lhs, from!"clang".Cursor rhs)
    in(lhs.kind == rhs.kind)
    do
{
    import clang: Cursor;
    return lhs.kind == Cursor.Kind.Namespace
        ? mergeNodes(lhs, rhs)
        : mergeLeaves(lhs, rhs);
}


// Takes two namespaces with the same name and returns a new namespace cursor
// with merged declarations from each
from!"clang".Cursor mergeNodes(from!"clang".Cursor lhs, from!"clang".Cursor rhs)
    in(lhs.kind == from!"clang".Cursor.Kind.Namespace &&
       rhs.kind == from!"clang".Cursor.Kind.Namespace &&
       lhs.spelling == rhs.spelling)
    do
{
    import clang: Cursor;
    import std.algorithm: filter, countUntil;
    import std.array: front, empty;

    auto ret = Cursor(Cursor.Kind.Namespace, lhs.spelling);
    ret.children = canonicalCursors(lhs.children);

    foreach(child; rhs.children) {
        const alreadyHaveIndex = ret.children.countUntil!(a => a.kind == child.kind &&
                                                               a.spelling == child.spelling);
        // no such cursor yet, add it to the list
        if(alreadyHaveIndex == -1)
            ret.children = ret.children ~ child;
        else {
            auto merge = child.kind == Cursor.Kind.Namespace ? &mergeNodes : &mergeLeaves;

            ret.children =
                ret.children[0 .. alreadyHaveIndex] ~
                ret.children[alreadyHaveIndex + 1 .. $] ~
                merge(ret.children[alreadyHaveIndex], child);
        }
    }

    return ret;
}


// Merges two cursors so that the "best" one is returned. Avoid double definitions
// that are allowed in C but not in D
from!"clang".Cursor mergeLeaves(from!"clang".Cursor lhs, from!"clang".Cursor rhs)
    in(lhs.kind != from!"clang".Cursor.Kind.Namespace &&
       rhs.kind != from!"clang".Cursor.Kind.Namespace)
    do
{
    import clang: Cursor;
    import std.algorithm: sort, chunkBy, map, filter;
    import std.array: array, join;
    import std.range: chain;

    // Filter out "ghosts" (useless repeated cursors).
    // Each element of `cursors` has the same canonical cursor.
    static Cursor cursorFromCanonicals(Cursor[] cursors) {
        import clang: Cursor;
        import std.algorithm: all, filter;
        import std.array: array, save, front, empty;

        auto definitions = cursors.save.filter!(a => a.isDefinition);
        if(!definitions.empty) return definitions.front;

        auto canonicals = cursors.save.filter!(a => a.isCanonical);
        if(!canonicals.empty) return canonicals.front;

        assert(!cursors.empty);
        return cursors.front;
    }

    return cursorFromCanonicals([lhs, rhs]);
}



bool isCppHeader(in from!"dpp.runtime.options".Options options, in string headerFileName) @safe pure {
    import std.path: extension;
    if(options.parseAsCpp) return true;
    return headerFileName.extension != ".h";
}


string getHeaderName(in const(char)[] line, in string[] includePaths)
    @safe
{
    const name = getHeaderName(line);
    return name == "" ? name : fullPath(includePaths, name);
}


string getHeaderName(const(char)[] line)
    @safe pure
{
    import std.algorithm: startsWith, countUntil;
    import std.range: dropBack;
    import std.array: popFront;
    import std.string: stripLeft;

    line = line.stripLeft;
    if(!line.startsWith(`#include `)) return "";

    const openingQuote = line.countUntil!(a => a == '"' || a == '<');
    const closingQuote = line[openingQuote + 1 .. $].countUntil!(a => a == '"' || a == '>') + openingQuote + 1;
    return line[openingQuote + 1 .. closingQuote].idup;
}

///
@("getHeaderName")
@safe pure unittest {
    import unit_threaded: shouldEqual;
    getHeaderName(`#include "foo.h"`).shouldEqual(`foo.h`);
    getHeaderName(`#include "bar.h"`).shouldEqual(`bar.h`);
    getHeaderName(`#include "foo.h" // comment`).shouldEqual(`foo.h`);
    getHeaderName(`#include <foo.h>`).shouldEqual(`foo.h`);
    getHeaderName(`    #include "foo.h"`).shouldEqual(`foo.h`);
}



// transforms a header name, e.g. stdio.h
// into a full file path, e.g. /usr/include/stdio.h
private string fullPath(in string[] includePaths, in string headerName) @safe {

    import std.algorithm: map, filter;
    import std.path: buildPath, absolutePath;
    import std.file: exists;
    import std.conv: text;
    import std.exception: enforce;

    if(headerName.exists) return headerName;

    auto filePaths = includePaths
        .map!(a => buildPath(a, headerName).absolutePath)
        .filter!exists;

    enforce(!filePaths.empty, text("d++ cannot find file path for header '", headerName, "'"));

    return filePaths.front;
}
