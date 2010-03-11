# Nixpkgs/NixOS option handling.

let lib = import ./default.nix; in

with { inherit (builtins) head tail; };
with import ./trivial.nix;
with import ./lists.nix;
with import ./misc.nix;
with import ./attrsets.nix;
with import ./properties.nix;

rec {

  inherit (lib) typeOf;
  

  isOption = attrs: (typeOf attrs) == "option";
  mkOption = attrs: attrs // {
    _type = "option";
    # name (this is the name of the attributem it is automatically generated by the traversal)
    # default (value used when no definition exists)
    # example (documentation)
    # description (documentation)
    # type (option type, provide a default merge function and ensure type correctness)
    # merge (function used to merge definitions into one definition: [ /type/ ] -> /type/)
    # apply (convert the option value to ease the manipulation of the option result)
    # options (set of sub-options declarations & definitions)
    # extraConfigs (list of possible configurations)
  };

  mapSubOptions = f: opt:
    if opt ? options then
      opt // {
        options = map f (toList opt.options);
      }
    else
      opt;

  # Make the option declaration more user-friendly by adding default
  # settings and some verifications based on the declaration content (like
  # type correctness).
  addOptionMakeUp = {name, recurseInto}: decl:
    let
      init = {
        inherit name;
        merge = mergeDefaultOption;
        apply = lib.id;
      };

      functionsFromType = opt:
        if decl ? type && decl.type ? merge then
          opt
          // optionalAttrs (decl.type ? merge) { inherit (decl.type) merge; }
          // optionalAttrs (decl.type ? check) { inherit (decl.type) check; }
        else
          opt;

      addDeclaration = opt: opt // decl;

      ensureMergeInputType = opt:
        if opt ? check then
          opt // {
            merge = list:
              if all opt.check list then
                opt.merge list
              else
                throw "One of the definitions has a bad type.";
          }
        else opt;

      ensureDefaultType = opt:
        if opt ? check && opt ? default then
          opt // {
            default =
              if opt.check opt.default then
                opt.default
              else
                throw "The default value has a bad type.";
          }
        else opt;

      handleOptionSets = opt:
        if opt ? type && opt.type.hasOptions then
          let
            
            optionConfig = vals: args:
              map (f: lib.applyIfFunction f args)
                (opt.options ++ toList vals);

            # Evaluate sub-modules.
            subModuleMerge = path: vals:
              lib.fix (args:
                let result = recurseInto path (optionConfig vals args); in {
                  inherit (result) config options;
                  name = lib.removePrefix (opt.name + ".") path;
                }
              );

            # Add _options in sub-modules to make it viewable from other
            # modules.
            subModuleMergeConfig = path: vals:
              let result = subModuleMerge path vals; in
                { _args = result; } // result.config;

          in
            opt // {
              merge = list:
                opt.type.iter
                  subModuleMergeConfig
                  opt.name
                  (opt.merge list);
              options =
                let path = opt.type.docPath opt.name; in
                  (subModuleMerge path []).options;
            }
        else
          opt;
    in
      foldl (opt: f: f opt) init [
        # default settings
        functionsFromType

        # user settings
        addDeclaration

        # override settings
        ensureMergeInputType
        ensureDefaultType
        handleOptionSets
      ];

  # Merge a list of options containning different field.  This is useful to
  # separate the merge & apply fields from the interface.
  mergeOptionDecls = opts:
    if opts == [] then {}
    else if tail opts == [] then
      let opt = head opts; in
      if opt ? options then
        opt // { options = toList opt.options; }
      else
        opt
    else
      fold (opt1: opt2:
        lib.addErrorContext "opt1 = ${lib.showVal opt1}\nopt2 = ${lib.showVal opt2}" (
        # You cannot merge if two options have the same field.
        assert opt1 ? default -> ! opt2 ? default;
        assert opt1 ? example -> ! opt2 ? example;
        assert opt1 ? description -> ! opt2 ? description;
        assert opt1 ? merge -> ! opt2 ? merge;
        assert opt1 ? apply -> ! opt2 ? apply;
        assert opt1 ? type -> ! opt2 ? type;
        opt1 // opt2
        // optionalAttrs (opt1 ? options || opt2 ? options) {
            options =
               (toList (attrByPath ["options"] [] opt1))
            ++ (toList (attrByPath ["options"] [] opt2));
          }
        // optionalAttrs (opt1 ? extraConfigs || opt2 ? extraConfigs) {
            extraConfigs =
               (attrByPath ["extraConfigs"] [] opt1)
            ++ (attrByPath ["extraConfigs"] [] opt2);
          }
      )) {} opts;

  
  # !!! This function will be removed because this can be done with the
  # multiple option declarations.
  addDefaultOptionValues = defs: opts: opts //
    builtins.listToAttrs (map (defName:
      { name = defName;
        value = 
          let
            defValue = builtins.getAttr defName defs;
            optValue = builtins.getAttr defName opts;
          in
          if typeOf defValue == "option"
          then
            # `defValue' is an option.
            if hasAttr defName opts
            then builtins.getAttr defName opts
            else defValue.default
          else
            # `defValue' is an attribute set containing options.
            # So recurse.
            if hasAttr defName opts && isAttrs optValue 
            then addDefaultOptionValues defValue optValue
            else addDefaultOptionValues defValue {};
      }
    ) (attrNames defs));

  mergeDefaultOption = list:
    if list != [] && tail list == [] then head list
    else if all builtins.isFunction list then x: mergeDefaultOption (map (f: f x) list)
    else if all isList list then concatLists list
    else if all isAttrs list then fold lib.mergeAttrs {} list
    else if all builtins.isBool list then fold lib.or false list
    else if all builtins.isString list then lib.concatStrings list
    else throw "Cannot merge values.";

  mergeTypedOption = typeName: predicate: merge: list:
    if all predicate list then merge list
    else throw "Expect a ${typeName}.";

  mergeEnableOption = mergeTypedOption "boolean"
    (x: true == x || false == x) (fold lib.or false);

  mergeListOption = mergeTypedOption "list" isList concatLists;

  mergeStringOption = mergeTypedOption "string"
    (x: if builtins ? isString then builtins.isString x else x + "")
    lib.concatStrings;

  mergeOneOption = list:
    if list == [] then abort "This case should never happen."
    else if tail list != [] then throw "Multiple definitions. Only one is allowed for this option."
    else head list;


  fixableMergeFun = merge: f: config:
    merge (
      # generate the list of option sets.
      f config
    );

  fixableMergeModules = merge: initModules: {...}@args: config:
    fixableMergeFun merge (config:
      lib.moduleClosure initModules (args // { inherit config; })
    ) config;


  fixableDefinitionsOf = initModules: {...}@args:
    fixableMergeModules (modules: (lib.moduleMerge "" modules).config) initModules args;

  fixableDeclarationsOf = initModules: {...}@args:
    fixableMergeModules (modules: (lib.moduleMerge "" modules).options) initModules args;

  definitionsOf = initModules: {...}@args:
    (lib.fix (module:
      fixableMergeModules (lib.moduleMerge "") initModules args module.config
    )).config;

  declarationsOf = initModules: {...}@args:
    (lib.fix (module:
      fixableMergeModules (lib.moduleMerge "") initModules args module.config
    )).options;


  # Generate documentation template from the list of option declaration like
  # the set generated with filterOptionSets.
  optionAttrSetToDocList = ignore: newOptionAttrSetToDocList;
  newOptionAttrSetToDocList = attrs:
    let tryEval = v:
      let res = builtins.tryEval v; in
      if builtins ? tryEval then
        if res.success then res.value else "<error>"
      else v;
    in
    let options = collect isOption attrs; in
      fold (opt: rest:
        let
          docOption = {
            inherit (opt) name;
            description = if opt ? description then opt.description else
              throw "Option ${opt.name}: No description.";

            declarations = map (x: toString x.source) opt.declarations;
            definitions = map (x: toString x.source) opt.definitions;
          }
          // optionalAttrs (opt ? example) { example = tryEval opt.example; }
          // optionalAttrs (opt ? default) { default = tryEval opt.default; };

          subOptions =
            if opt ? options then
              newOptionAttrSetToDocList opt.options
            else
              [];
        in
          [ docOption ] ++ subOptions ++ rest
      ) [] options;


}
