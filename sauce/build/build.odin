#+feature dynamic-literals
/*

Build script.

Note: doesn't make sense to abstract this away for re-use.
There's too many project-specific settings here, so it's not worth the effort.

*/


package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:os/os2"
import path "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:time"

// we are assuming we're right next to the bald collection
import utils "../bald/utils"
import logger "../bald/utils/logger"

EXE_NAME :: "game"

Target :: enum {
	windows,
	mac,
}

main :: proc() {
	context.logger = logger.logger()
	context.assertion_failure_proc = logger.assertion_failure_proc

	// We should already be in the project root thanks to the bash script
	fmt.println("Current directory:", os.get_current_directory())

	// Verify we're in the right place
	if !os.exists("sauce") {
		log.error("Could not find 'sauce' directory. Are we in the right project root?")
		log.error("Current directory:", os.get_current_directory())
		log.error("Directory contents:")

		// List what's in the current directory to help debug
		handle, err := os.open(".")
		if err == os.ERROR_NONE {
			defer os.close(handle)
			file_infos, read_err := os.read_dir(handle, -1)
			if read_err == os.ERROR_NONE {
				defer delete(file_infos)
				for info in file_infos {
					log.error("  -", info.name)
				}
			}
		}
		return
	}

	start_time := time.now()

	// note, ODIN_OS is built in, but we're being explicit
	assert(ODIN_OS == .Windows || ODIN_OS == .Darwin, "unsupported OS target")

	target: Target
	#partial switch ODIN_OS {
	case .Windows:
		target = .windows
	case .Darwin:
		target = .mac
	case:
		{
			log.error("Unsupported os:", ODIN_OS)
			return
		}
	}
	fmt.println("Building for", target)

	// gen the generated.odin
	{
		file := "sauce/generated.odin"

		f, err := os.open(file, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
		if err != nil {
			fmt.eprintln("Error:", err)
		}
		defer os.close(f)

		using fmt
		fprintln(f, "//")
		fprintln(f, "// MACHINE GENERATED via build.odin")
		fprintln(f, "// do not edit by hand!")
		fprintln(f, "//")
		fprintln(f, "")
		fprintln(f, "package main")
		fprintln(f, "")
		fprintln(f, "Platform :: enum {")
		fprintln(f, "	windows,")
		fprintln(f, "	mac,")
		fprintln(f, "}")
		fprintln(f, tprintf("PLATFORM :: Platform.%v", target))
	}

	// generate the shader
	// docs: https://github.com/floooh/sokol-tools/blob/master/docs/sokol-shdc.md
	utils.fire(
		"sokol-shdc",
		"-i",
		"sauce/bald/draw/shader_core.glsl",
		"-o",
		"sauce/bald-user/generated_shader.odin",
		"-l",
		"hlsl5:metal_macos",
		"-f",
		"sokol_odin",
	)

	wd := os.get_current_directory()

	out_dir: string
	switch target {
	case .windows:
		out_dir = "build/windows_debug"
	case .mac:
		out_dir = "build/mac_debug"
	}

	full_out_dir_path := fmt.tprintf("%v/%v", wd, out_dir)
	log.info(full_out_dir_path)
	utils.make_directory_if_not_exist(full_out_dir_path)

	// build command
	{
		c: [dynamic]string = {
			"odin",
			"build",
			"sauce",
			"-debug",
			"-collection:bald=sauce/bald",
			"-collection:user=sauce",
			fmt.tprintf("-out:%v/%v.exe", out_dir, EXE_NAME),
		}
		utils.fire(..c[:])
	}

	// copy stuff into folder
	{
		// NOTE, if it already exists, it won't copy (to save build time)
		files_to_copy: [dynamic]string
		folders_to_copy: [dynamic]string

		switch target {
		case .windows:
			append(&files_to_copy, "sauce/bald/sound/fmod/studio/lib/windows/x64/fmodstudio.dll")
			append(&files_to_copy, "sauce/bald/sound/fmod/studio/lib/windows/x64/fmodstudioL.dll")
			append(&files_to_copy, "sauce/bald/sound/fmod/core/lib/windows/x64/fmod.dll")
			append(&files_to_copy, "sauce/bald/sound/fmod/core/lib/windows/x64/fmodL.dll")

		case .mac:
			append(&files_to_copy, "sauce/bald/sound/fmod/studio/lib/darwin/libfmodstudio.dylib")
			append(&files_to_copy, "sauce/bald/sound/fmod/studio/lib/darwin/libfmodstudioL.dylib")
			append(&files_to_copy, "sauce/bald/sound/fmod/core/lib/darwin/libfmod.dylib")
			append(&files_to_copy, "sauce/bald/sound/fmod/core/lib/darwin/libfmodL.dylib")

			append(&folders_to_copy, "res")
		}

		// Copy individual files
		for src in files_to_copy {
			fmt.println("Checking file:", src)
			if !os.exists(src) {
				fmt.printf("WARNING: Source file does not exist: %v\n", src)
				continue
			}

			dir, file_name := path.split(src)
			dest := fmt.tprintf("%v/%v", out_dir, file_name)
			if !os.exists(dest) {
				fmt.printf("Copying %v -> %v\n", src, dest)
				err := os2.copy_file(dest, src)
				if err != nil {
					fmt.printf("Error copying file %v: %v\n", src, err)
				}
			} else {
				fmt.printf("File already exists, skipping: %v\n", dest)
			}
		}

		// Copy entire folders
		for src_folder in folders_to_copy {
			fmt.println("Checking folder:", src_folder)
			if !os.exists(src_folder) {
				fmt.printf("WARNING: Source folder does not exist: %v\n", src_folder)
				continue
			}

			_, folder_name := path.split(src_folder)
			dest_folder := fmt.tprintf("%v/%v", out_dir, folder_name)

			if !os.exists(dest_folder) {
				fmt.printf("Copying folder %v -> %v\n", src_folder, dest_folder)
				copy_folder_recursive(dest_folder, src_folder)
			} else {
				fmt.printf("Folder already exists, skipping: %v\n", dest_folder)
			}
		}
	}

	fmt.println("DONE in", time.diff(start_time, time.now()))
}

// Helper function to recursively copy folders
copy_folder_recursive :: proc(dest: string, src: string) {
	// Create destination directory
	os.make_directory(dest)

	// Read all entries in source directory
	handle, err := os.open(src)
	if err != os.ERROR_NONE {
		fmt.printf("Error opening directory %v: %v\n", src, err)
		return
	}
	defer os.close(handle)

	file_infos, read_err := os.read_dir(handle, -1) // -1 means read all
	if read_err != os.ERROR_NONE {
		fmt.printf("Error reading directory %v: %v\n", src, read_err)
		return
	}
	defer delete(file_infos)

	for info in file_infos {
		src_path := fmt.tprintf("%v/%v", src, info.name)
		dest_path := fmt.tprintf("%v/%v", dest, info.name)

		if info.is_dir {
			// Recursively copy subdirectory
			copy_folder_recursive(dest_path, src_path)
		} else {
			// Copy file
			os2.copy_file(dest_path, src_path)
		}
	}
}

// value extraction example:
/*
target: Target
found: bool
for arg in os2.args {
	if strings.starts_with(arg, "target:") {
		target_string := strings.trim_left(arg, "target:")
		value, ok := reflect.enum_from_name(Target, target_string)
		if ok {
			target = value
			found = true
			break
		} else {
			log.error("Unsupported target:", target_string)
		}
	}
}
*/

