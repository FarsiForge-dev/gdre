extends Node

# Godot RE Tools — FarsiForge Dedicated CLI Edition
# Streamlined, headless-first, zero GUI bloat, with comprehensive Font Detection.

const ERR_SKIP = 45

var scripts_only: bool = false
var translation_only: bool = false
var ret_code: int = 0
var SCRIPTS_EXT = ["gd", "gdc", "gde"]

const MAIN_COMMANDS = [
	"--recover",
	"--extract",
	"--detect-fonts",
	"--list-fonts",
	"--compile",
	"--decompile",
	"--list-bytecode-versions",
	"--pck-create",
	"--pck-patch",
	"--patch-translations",
	"--txt-to-bin",
	"--bin-to-txt",
	"--list-files"
]

const GLOB_NOTES = """Notes on Include/Exclude globs:
- Recursive patterns can be specified with '**'
- Globs should be rooted to 'res://' or 'user://'
"""

func _ready() -> void:
	var args = get_sanitized_args()
	handle_cli(args)
	get_tree().quit(ret_code)

func print_version() -> void:
	print("Godot RE Tools (FarsiForge Edition) v" + GDRESettings.get_gdre_version())

func print_usage() -> void:
	print_version()
	print("""
Usage:
  gdre_tools --headless <command> [options]

Commands:
  --recover=<PCK/EXE/APK/DIR>          Full project recovery (extracts PCK, decompiles bytecode, converts binary resources)
  --extract=<PCK/EXE/APK>              Extract raw files from PCK archive
  --detect-fonts=<PCK/EXE/DIR>         Scan and detect all font resources (TTF, OTF, WOFF, FontData, BitmapFont)
  --list-fonts=<PCK/EXE/DIR>           Alias for --detect-fonts
  --list-files=<PCK/EXE/APK>           List all packed files inside archive
  --compile=<GD_FILE>                  Compile GDScript code to bytecode (requires --bytecode)
  --decompile=<GDC_FILE>               Decompile GDC bytecode back to GDScript code
  --pck-create=<DIR>                   Create a new PCK archive from directory
  --pck-patch=<PCK/EXE>                Patch PCK archive with replacement files
  --patch-translations=<CSV>=<RES>     Inject translated strings into PCK translation resources
  --txt-to-bin=<FILE>                  Convert text-based scene/resource (.tscn/.tres) to binary (.scn/.res)
  --bin-to-txt=<FILE>                  Convert binary scene/resource (.scn/.res) to text (.tscn/.tres)
  --list-bytecode-versions             List supported GDScript bytecode revisions
  --version, --gdre-version            Print version information
  --help, --gdre-help                  Print this help message

Options:
  --output=<DIR>                       Output directory path
  --key=<KEY>                          64-character hex decryption key for encrypted archives
  --include=<GLOB>                     Include matching file patterns (can be repeated)
  --exclude=<GLOB>                     Exclude matching file patterns (can be repeated)
  --scripts-only                       Only recover/extract script files (.gd/.gdc)
  --translation-only                   Only recover translation files (.translation)
  --ignore-checksum-errors             Continue extraction even if MD5 checksum fails
  --skip-checksum-check                Skip MD5 checksum verification
  --bytecode=<VERSION/COMMIT>          Target engine version (e.g. 4.3.0) or bytecode commit hash
""")

func dequote(arg: String) -> String:
	if arg.begins_with("\"") and arg.ends_with("\""):
		return arg.substr(1, arg.length() - 2)
	if arg.begins_with("'") and arg.ends_with("'"):
		return arg.substr(1, arg.length() - 2)
	return arg

func split_args(args_str: String, splitter: String = ",") -> PackedStringArray:
	var parts = args_str.split(splitter, false)
	for i in range(parts.size()):
		parts[i] = dequote(parts[i].strip_edges())
	return parts

func get_arg_value(arg: String) -> String:
	var split_val = arg.split("=", true, 1)
	if split_val.size() == 2:
		return dequote(split_val[1])
	return ""

func get_cli_abs_path(path: String) -> String:
	path = path.simplify_path()
	if path.is_absolute_path():
		return path
	var exec_path = GDRESettings.get_exec_dir()
	if path.begins_with("~/"):
		return GDRESettings.get_home_dir() + path.trim_prefix("~")
	return exec_path.path_join(path).simplify_path()

func get_sanitized_args() -> PackedStringArray:
	var args = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if args.size() > 0 and args[0] == "--scene":
		args = args.slice(1)
	if args.size() > 0 and args[0].begins_with("res://gdre") and args[0].ends_with(".tscn"):
		args = args.slice(1)
	if args.size() > 0 and args[0].begins_with("#") and args[0].substr(1).is_valid_hex_number():
		args = args.slice(1)
	return args

func get_glob_files(glob_pat: String) -> PackedStringArray:
	var files: PackedStringArray = Glob.rglob(glob_pat, true)
	if files.size() == 0 and FileAccess.file_exists(glob_pat):
		files.append(glob_pat)
	return files

func get_globs_files(globs: PackedStringArray) -> PackedStringArray:
	var files: PackedStringArray = []
	for glob in globs:
		files.append_array(get_glob_files(glob))
	return files

func normalize_cludes(cludes: PackedStringArray, dir: String = "res://") -> PackedStringArray:
	var new_cludes: PackedStringArray = []
	if dir != dir.get_base_dir() and dir.ends_with("/"):
		dir = dir.substr(0, dir.length() - 1)
	for clude in cludes:
		clude = clude.replace("\\", "/")
		if not "**" in clude and "*" in clude and not "/" in clude:
			new_cludes.append("res://**/" + clude)
			continue
		if clude.begins_with("/") and dir == "res://":
			clude = clude.substr(1, clude.length() - 1)
		if not clude.is_absolute_path():
			clude = dir.path_join(clude)
		elif dir != "res://":
			clude = clude.replace("res:/", dir)
		elif clude.begins_with("/"):
			clude = dir + clude.substr(1, clude.length() - 1)
		new_cludes.append(clude.simplify_path())
	return new_cludes

func ensure_dir_exists(dir_path: String) -> void:
	var da: DirAccess = DirAccess.open(GDRESettings.get_exec_dir())
	if da and not da.dir_exists(dir_path):
		da.make_dir_recursive(dir_path)

func dump_files(output_dir: String, files: PackedStringArray, ignore_checksum_errors: bool = false, skip_md5: bool = false) -> int:
	var pckdump = PckDumper.new()
	var err: int = OK
	if not skip_md5:
		err = pckdump.check_md5_all_files()
	if err != OK:
		if err != ERR_SKIP and not ignore_checksum_errors:
			print("[ERROR] MD5 checksum verification failed, aborting.")
			return err
		elif ignore_checksum_errors:
			print("[WARN] MD5 checksum verification failed, proceeding due to --ignore-checksum-errors.")
	err = pckdump.pck_dump_to_dir(output_dir, files)
	if err != OK:
		print("[ERROR] Failed to dump files to destination directory: " + output_dir)
	return err

func export_imports(output_dir: String, files: PackedStringArray) -> int:
	var importer: ImportExporter = ImportExporter.new()
	var ret = importer.export_imports(output_dir, files)
	importer.reset()
	return ret

# ==============================================================================
# FONT DETECTION & REPORTING
# ==============================================================================
func detect_and_report_fonts(target_path: String, output_report_path: String = "") -> int:
	var abs_target = get_cli_abs_path(target_path)
	print("\n============================================================")
	print(" [FarsiForge] Font Detection Scanner")
	print(" Scanning target: " + abs_target)
	print("============================================================")

	if not FileAccess.file_exists(abs_target) and not DirAccess.dir_exists_absolute(abs_target):
		print("[ERROR] Target file or directory does not exist: " + abs_target)
		return 1

	var err = GDRESettings.load_project([abs_target])
	if err != OK:
		print("[ERROR] Failed to load Godot pack/project: " + abs_target)
		return 1

	var file_infos = GDRESettings.get_file_info_array()
	var fonts_found: Array[Dictionary] = []
	var known_font_exts = ["ttf", "otf", "woff", "woff2", "fontdata", "fnt", "font", "ttc", "otc"]

	for info in file_infos:
		var file_path: String = info.get_path()
		var ext = file_path.get_extension().to_lower()
		var is_font = false
		var font_category = ""

		if ext in ["ttf", "otf", "ttc", "otc"]:
			is_font = true
			font_category = "TrueType / OpenType (" + ext.to_upper() + ")"
		elif ext in ["woff", "woff2"]:
			is_font = true
			font_category = "Web Open Font (" + ext.to_upper() + ")"
		elif ext == "fontdata":
			is_font = true
			font_category = "Godot 4 FontData Resource"
		elif ext in ["fnt", "font"]:
			is_font = true
			font_category = "Bitmap Font Definition"
		elif file_path.to_lower().contains("/font/") or file_path.to_lower().contains("/fonts/"):
			if ext in ["tres", "res", "remap", "import"]:
				is_font = true
				font_category = "Font Scene/Resource Reference (" + ext + ")"

		if is_font:
			var font_entry = {
				"path": file_path,
				"category": font_category,
				"extension": ext,
				"size_bytes": info.get_size(),
				"compressed": info.is_compressed(),
				"encrypted": info.is_encrypted()
			}
			fonts_found.append(font_entry)

	print("Total Fonts Detected: %d" % fonts_found.size())
	if fonts_found.size() > 0:
		for i in range(fonts_found.size()):
			var f = fonts_found[i]
			var size_kb = float(f["size_bytes"]) / 1024.0
			print("  [%2d] %-30s | %8.1f KB | %s" % [i + 1, f["category"], size_kb, f["path"]])
	else:
		print("  No explicit font resources detected in archive.")
	print("============================================================\n")

	if not output_report_path.is_empty():
		output_report_path = get_cli_abs_path(output_report_path)
		var report_data = {
			"scanner": "FarsiForge GDRE Font Detector",
			"target": abs_target,
			"timestamp": Time.get_datetime_string_from_system(),
			"engine_version": GDRESettings.get_version_string(),
			"total_fonts": fonts_found.size(),
			"fonts": fonts_found
		}
		var json_text = JSON.stringify(report_data, "  ")
		var out_file = FileAccess.open(output_report_path, FileAccess.WRITE)
		if out_file:
			out_file.store_string(json_text)
			out_file.close()
			print("[SUCCESS] Font report exported to: " + output_report_path)
		else:
			print("[ERROR] Failed to write font report to: " + output_report_path)

	GDRESettings.unload_project()
	return 0

# ==============================================================================
# PROJECT RECOVERY & EXTRACTION
# ==============================================================================
func recovery(input_files: PackedStringArray,
			  output_dir: String,
			  enc_key: String,
			  extract_only: bool,
			  ignore_checksum_errors: bool = false,
			  excludes: PackedStringArray = [],
			  includes: PackedStringArray = [],
			  skip_md5: bool = false) -> int:

	var resolved_inputs: PackedStringArray = []
	for file_entry in input_files:
		var abs_p = get_cli_abs_path(file_entry)
		var globs = get_glob_files(abs_p)
		if globs.size() > 0:
			resolved_inputs.append_array(globs)
		else:
			print("[ERROR] Failed to locate input file: " + file_entry)
			return 1

	if resolved_inputs.size() == 0:
		print("[ERROR] No valid input files found.")
		return 1

	var target_input = resolved_inputs[0]
	if output_dir == "":
		output_dir = target_input.get_basename() + ("_extracted" if extract_only else "_recovered")
	else:
		output_dir = get_cli_abs_path(output_dir)

	var start_time = Time.get_ticks_msec()
	print("[INFO] Loading package: " + target_input)

	if not enc_key.is_empty():
		if GDRESettings.set_encryption_key_string(enc_key) != OK:
			print("[ERROR] Invalid 64-character encryption key provided.")
			return 1

	var err = GDRESettings.load_project(resolved_inputs)
	if err != OK:
		var err_msg = GDRESettings.get_recent_error_string()
		if err_msg.to_lower().contains("encrypt"):
			err_msg = "Incorrect encryption key. Please provide the valid key via --key."
		print("[ERROR] Failed to load archive:\n" + err_msg)
		return 1

	print("[INFO] Archive loaded successfully. Godot Version: " + GDRESettings.get_version_string())

	var files_to_dump: PackedStringArray = []
	if translation_only:
		for f in GDRESettings.get_file_list():
			var ext = f.get_extension().to_lower()
			if ext == "translation" or ext == "xl":
				files_to_dump.append(f)
		print("[INFO] Translation-only mode: %d files selected." % files_to_dump.size())
	elif scripts_only:
		for f in GDRESettings.get_file_list():
			if f.get_extension().to_lower() in SCRIPTS_EXT:
				files_to_dump.append(f)
		print("[INFO] Scripts-only mode: %d files selected." % files_to_dump.size())
	else:
		if includes.size() > 0:
			includes = normalize_cludes(includes, "res://")
			files_to_dump = get_globs_files(includes)
		else:
			files_to_dump = GDRESettings.get_file_list()
		if excludes.size() > 0:
			excludes = normalize_cludes(excludes, "res://")
			files_to_dump = Glob.fnmatch_list(files_to_dump, excludes, true)

	if files_to_dump.size() == 0:
		print("[WARN] No files matched the requested filters.")
		GDRESettings.unload_project()
		return 1

	ensure_dir_exists(output_dir)
	err = dump_files(output_dir, files_to_dump, ignore_checksum_errors, skip_md5)
	if err != OK:
		print("[ERROR] Failed to unpack archive files.")
		GDRESettings.unload_project()
		return 1

	if extract_only:
		var elapsed = (Time.get_ticks_msec() - start_time) / 1000.0
		print("[SUCCESS] Extraction completed in %.2f seconds (%d files)." % [elapsed, files_to_dump.size()])
		GDRESettings.unload_project()
		return 0

	print("[INFO] Converting resources and decompiling scripts...")
	var importer: ImportExporter = ImportExporter.new()
	err = importer.export_imports(output_dir, files_to_dump)
	if err != OK and err != ERR_SKIP:
		print("[WARN] Asset recovery finished with warnings: " + GDRESettings.get_recent_error_string())

	var elapsed_rec = (Time.get_ticks_msec() - start_time) / 1000.0
	print("[SUCCESS] Project recovery completed in %.2f seconds." % elapsed_rec)

	# Automatic font detection in the recovered output directory
	var report_path = output_dir.path_join("gdre_fonts_report.json")
	detect_and_report_fonts(target_input, report_path)

	GDRESettings.unload_project()
	return 0

# ==============================================================================
# SCRIPT DECOMPILATION & COMPILATION
# ==============================================================================
func get_decomp(bytecode_ver: String) -> GDScriptDecomp:
	var decomp: GDScriptDecomp = null
	if "." in bytecode_ver:
		decomp = GDScriptDecomp.create_decomp_for_version(bytecode_ver)
	else:
		decomp = GDScriptDecomp.create_decomp_for_commit(bytecode_ver.hex_to_int())
	if decomp == null:
		print("[ERROR] Failed to create decompiler for bytecode: " + bytecode_ver)
	return decomp

func decompile(files: PackedStringArray, bytecode_ver: String, out_dir: String, _key: String = "") -> int:
	if out_dir.is_empty():
		out_dir = get_cli_abs_path(".")
	if bytecode_ver.is_empty():
		print("[ERROR] --bytecode is required for decompilation (e.g. --bytecode=4.3.0)")
		return 1
	var decomp: GDScriptDecomp = get_decomp(bytecode_ver)
	if decomp == null:
		return 1
	var matched = get_globs_files(files)
	if matched.size() == 0:
		print("[ERROR] No files found to decompile.")
		return 1
	ensure_dir_exists(out_dir)
	for f in matched:
		var code: String = decomp.decompile_byte_code(f)
		if code.is_empty():
			print("[ERROR] Failed to decompile: " + f)
			continue
		var out_p = out_dir.path_join(f.get_file().replace(".gdc", ".gd"))
		var out_f = FileAccess.open(out_p, FileAccess.WRITE)
		if out_f:
			out_f.store_string(code)
			out_f.close()
			print("  [DECOMPILED] %s -> %s" % [f, out_p])
	return 0

func compile(files: PackedStringArray, bytecode_ver: String, out_dir: String) -> int:
	if out_dir.is_empty():
		out_dir = get_cli_abs_path(".")
	if bytecode_ver.is_empty():
		print("[ERROR] --bytecode is required for compilation (e.g. --bytecode=4.3.0)")
		return 1
	var decomp: GDScriptDecomp = get_decomp(bytecode_ver)
	if decomp == null:
		return 1
	var matched = get_globs_files(files)
	if matched.size() == 0:
		print("[ERROR] No files found to compile.")
		return 1
	ensure_dir_exists(out_dir)
	for f in matched:
		var in_f = FileAccess.open(f, FileAccess.READ)
		if not in_f:
			print("[ERROR] Cannot read script: " + f)
			continue
		var code = in_f.get_as_text()
		in_f.close()
		var bytecode = decomp.compile_code_string(code)
		if bytecode.is_empty():
			print("[ERROR] Compilation failed for: " + f)
			continue
		var out_p = out_dir.path_join(f.get_file().replace(".gd", ".gdc"))
		var out_f = FileAccess.open(out_p, FileAccess.WRITE)
		if out_f:
			out_f.store_buffer(bytecode)
			out_f.close()
			print("  [COMPILED] %s -> %s" % [f, out_p])
	return 0

# ==============================================================================
# PCK CREATION & PATCHING
# ==============================================================================
func list_files(input_files: PackedStringArray) -> int:
	for f in input_files:
		var abs_f = get_cli_abs_path(f)
		var err = GDRESettings.load_project([abs_f])
		if err != OK:
			print("[ERROR] Failed to inspect: " + abs_f)
			continue
		print("\n--- Files in %s (%d files) ---" % [abs_f, GDRESettings.get_file_count()])
		for file_path in GDRESettings.get_file_list():
			print("  " + file_path)
		GDRESettings.unload_project()
	return 0

func patch_pck(src_file: String, dest_pck: String, patch_map: Dictionary, includes: PackedStringArray = [], excludes: PackedStringArray = [], enc_key: String = "", embed_pck: String = "") -> int:
	src_file = get_cli_abs_path(src_file)
	if dest_pck.is_empty():
		dest_pck = src_file.get_basename() + "_patched.pck"
	else:
		dest_pck = get_cli_abs_path(dest_pck)

	var err = GDRESettings.load_project([src_file])
	if err != OK:
		print("[ERROR] Failed to load source PCK: " + src_file)
		return 1

	var pck_creator = PckCreator.new()
	var pack_info = GDRESettings.get_pack_info(src_file)
	var engine_ver = pack_info.get_version()
	pck_creator.start_pck(dest_pck, pack_info.get_fmt_version(), engine_ver.major, engine_ver.minor, engine_ver.patch, pack_info.is_encrypted(), not embed_pck.is_empty(), embed_pck)

	for src_path in patch_map.keys():
		var res_path = patch_map[src_path]
		pck_creator.add_file(res_path, src_path)
		print("  [PATCH] Added %s -> %s" % [src_path, res_path])

	pck_creator.finish_pck()
	print("[SUCCESS] Patched PCK generated: " + dest_pck)
	return 0

# ==============================================================================
# MAIN CLI DISPATCHER
# ==============================================================================
func handle_cli(args: PackedStringArray) -> void:
	if args.size() == 0:
		print_usage()
		ret_code = 1
		return

	var input_recover: PackedStringArray = []
	var input_extract: PackedStringArray = []
	var input_detect_fonts: PackedStringArray = []
	var output_dir: String = ""
	var enc_key: String = ""
	var bytecode_ver: String = ""
	var decompile_files: PackedStringArray = []
	var compile_files: PackedStringArray = []
	var list_files_targets: PackedStringArray = []
	var pck_patch_src: String = ""
	var patch_map: Dictionary = {}
	var includes: PackedStringArray = []
	var excludes: PackedStringArray = []
	var ignore_checksum_errors: bool = false
	var skip_md5: bool = false

	var active_cmd: String = ""

	for arg in args:
		if arg == "--help" or arg == "--gdre-help":
			print_usage()
			ret_code = 0
			return
		elif arg == "--version" or arg == "--gdre-version":
			print_version()
			ret_code = 0
			return
		elif arg == "--list-bytecode-versions":
			print("Supported Godot engine bytecode revisions:")
			for v in GDScriptDecomp.get_bytecode_versions():
				print("  - " + v)
			ret_code = 0
			return
		elif arg.begins_with("--recover"):
			input_recover.append(get_arg_value(arg))
			active_cmd = "recover"
		elif arg.begins_with("--extract"):
			input_extract.append(get_arg_value(arg))
			active_cmd = "extract"
		elif arg.begins_with("--detect-fonts") or arg.begins_with("--list-fonts"):
			input_detect_fonts.append(get_arg_value(arg))
			active_cmd = "detect-fonts"
		elif arg.begins_with("--list-files"):
			list_files_targets.append(get_arg_value(arg))
			active_cmd = "list-files"
		elif arg.begins_with("--output") or arg.begins_with("--output-dir"):
			output_dir = get_arg_value(arg)
		elif arg.begins_with("--key"):
			enc_key = get_arg_value(arg)
		elif arg.begins_with("--bytecode"):
			bytecode_ver = get_arg_value(arg)
		elif arg.begins_with("--decompile"):
			decompile_files.append(get_arg_value(arg))
			active_cmd = "decompile"
		elif arg.begins_with("--compile"):
			compile_files.append(get_arg_value(arg))
			active_cmd = "compile"
		elif arg.begins_with("--include"):
			includes.append(get_arg_value(arg))
		elif arg.begins_with("--exclude"):
			excludes.append(get_arg_value(arg))
		elif arg == "--scripts-only":
			scripts_only = true
		elif arg == "--translation-only":
			translation_only = true
		elif arg == "--ignore-checksum-errors":
			ignore_checksum_errors = true
		elif arg == "--skip-checksum-check":
			skip_md5 = true
		elif arg.begins_with("--pck-patch"):
			pck_patch_src = get_arg_value(arg)
			active_cmd = "pck-patch"

	match active_cmd:
		"recover":
			ret_code = recovery(input_recover, output_dir, enc_key, false, ignore_checksum_errors, excludes, includes, skip_md5)
		"extract":
			ret_code = recovery(input_extract, output_dir, enc_key, true, ignore_checksum_errors, excludes, includes, skip_md5)
		"detect-fonts":
			if input_detect_fonts.size() == 0 or input_detect_fonts[0].is_empty():
				print("[ERROR] Path to PCK or directory is required for font detection.")
				ret_code = 1
			else:
				var report_json = output_dir if output_dir.ends_with(".json") else (output_dir.path_join("fonts_report.json") if not output_dir.is_empty() else "")
				ret_code = detect_and_report_fonts(input_detect_fonts[0], report_json)
		"list-files":
			ret_code = list_files(list_files_targets)
		"decompile":
			ret_code = decompile(decompile_files, bytecode_ver, output_dir, enc_key)
		"compile":
			ret_code = compile(compile_files, bytecode_ver, output_dir)
		"pck-patch":
			ret_code = patch_pck(pck_patch_src, output_dir, patch_map, includes, excludes, enc_key)
		_:
			if not active_cmd.is_empty():
				print("[ERROR] Unhandled command: " + active_cmd)
			else:
				print_usage()
			ret_code = 1
