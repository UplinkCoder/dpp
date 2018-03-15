module include.translation.typedef_;

import include.from;

string[] translateTypedef(in from!"clang".Cursor typedef_) @safe {

    import include.translation.aggregate: spellingOrNickname;
    import clang: Type;
    import std.conv: text;
    version(unittest) import unit_threaded.io: writelnUt;

    version(unittest)
        writelnUt("    TypedefDecl children: ", typedef_.children);

    assert(typedef_.children.length == 1 ||
           (typedef_.children.length == 0 && typedef_.type.kind == Type.Kind.Typedef),
           text("typedefs should only have 1 member, not ", typedef_.children.length));

    const spelling = typedef_.children.length
        ? spellingOrNickname(typedef_.children[0])
        : typedef_.underlyingType.spelling;

    return [`alias ` ~ typedef_.spelling ~ ` = ` ~ spelling  ~ `;`];
}