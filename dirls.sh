#! /usr/bin/env bash

# Dependecies:
# 	find, grep with PCRE support, sed, nc, wc, realpath, stat

function echo {
	printf "%s\n" "$*"
}

function uri_encode_path {
	# TODO
	printf "${URI_PREFIX}"
	sed 's/ /%20/g'
}

function uri_decode_path {
	# TODO
	sed 's/%20/ /g'
}

function html_escape {
	sed 's/\&/\&amp;/g' | sed 's/</\&lt;/g' | sed 's/>/\&gt;/g' \
		| sed 's/"/\&qout;/g' | sed 's/'\''/\&#39/g' # " and ' need to be escaped in attributes
}

# $1 - title
function html_template {
	read -r -d '' html_body
	read -r -d '' template <<- EOF
	<!DOCTYPE html>
	<html>
		<head>
			<meta charset="UTF-8" \\>
			<title>${1}</title>
			<style>${STYLE}</style>
		</head>
		<body>
			${html_body}
		</body>
	</html>
	EOF

	echo "${template}"
}

function path_sort {
	case "${DIRLS_SORT}" in
		asc)
			sort
			;;
		desc)
			sort -r
			;;
		*)
			cat -
			;;
	esac
}

# $1 - webroot
# $2 - path
function format_file {
	if [[ "${DIRLS_DETAILED}" == '' ]]
	then
		printf "<li><a href=\"%s\">%s</a></li>\n" \
			"$(uri_encode_path <<< "${1}/${2}" | html_escape)" \
			"$(html_escape <<< "${2}")"
	else
		printf "<details><summary><a href=\"%s\">%s</a></summary><pre>%s</pre></details>\n" \
			"$(uri_encode_path <<< "${1}/${2}" | html_escape)" \
			"$(html_escape <<< "${2}")" \
			"$(stat -- "${1}/${2}" | tail -n +2 | html_escape | sed 's/$/<br \/>/')"
	fi
}

# $1 - web root
function format_listing_html {
	local webroot dir_max_depth

	webroot="${1}"

	# TODO: handle paths containing newlines?
	dir_max_depth=2

	webroot_abs="$(realpath -- "${webroot}")"

	# Directories:
	printf "<h2>%s</h2>\n" ${webroot}
	printf '<a href="%s">..</a>\n' "$(realpath -- "${webroot}/.." | uri_encode_path | html_escape)"
	echo "<ul>"
	find "${webroot_abs}" -mindepth 1 -maxdepth ${dir_max_depth} -type d -printf '%P\n' \
		| path_sort | while read -r path
	do
		format_file "${webroot}" "${path}"
	done
	echo "</ul>"

	# Files:
	all_files="$(find "${webroot_abs}" -mindepth 1 -maxdepth 1 -not -type d -printf '%P\n' | path_sort)"
	files_categorized=()

	for category in "${categories[@]}"
	do
		local regex mime_regex path
		regex="${category_regexes["${category}"]}"

		if [[ "${regex}" =~ ^mime:.* ]]
		then
			mime_regex="${regex:5}"
			regex=''
		elif [[ "${regex}" =~ ^name:.* ]]
		then
			mime_regex=''
			regex="${regex:5}"
		else
			echo "invalid category specification for ${category} (expected 'name:' or 'mime:' prefix)" >&2
			continue
		fi

		cat_contains_any=false

		while IFS='' read -r path
		do
			# Avoid calling `file` if mime_regex is empty
			if [[ "${mime_regex}" != '' ]]
			then
				local mime
				mime="$(file -b --mime-type "${webroot}/${path}")"

				if ! grep -P -e "${mime_regex}" <<< "${mime}" >/dev/null
				then
					continue
				fi
			fi

			# Print the heading only if the category is not empty
			if [[ "${cat_contains_any}" != true ]]
			then
				cat_contains_any=true
				printf "<h3>%s:</h3>\n" $(printf "%s" "${category}" | html_escape)
				echo "<ul>"
			fi

			files_categorized+=("${path}")

			format_file "${webroot}" "${path}"
		# Avoid creating a subshell with process substitution
		done < <(grep -P -e "${regex}" <<< "${all_files}")

		if [[ "${cat_contains_any}" = true ]]
		then
			echo "</ul>"
		fi
	done

	local other_contains_any
	other_contains_any=false
	while read -r path
	do
		for i in "${files_categorized[@]}"
		do
			if [[ ${i} == "${path}" ]]
			then
				continue 2
			fi
		done

		if [[ "${other_contains_any}" != true ]]
		then
			other_contains_any=true
			echo "<h3>Other:</h3>"
			echo "<ul>"
		fi

		format_file "${webroot}" "${path}"
	done <<< "${all_files}"

	if [[ "${other_contains_any}" == true ]]
	then
		echo "</ul>"
	fi
}

# format_listing_html $(realpath .) | html_template "$(html_escape <<< "dirls - ${webroot}")"

function http_now {
	date -uR | sed 's/+0000/GMT/'
}

function http_handle_request {
	local method path version body content_type content_length http_status
	read -r method path version < <(head -n 1 | tr -d '\r' | tr -s ' ')

	path="$(uri_decode_path <<< "${path}")"

	if [[ "${method}" != 'GET' ]]
	then
		sed 's/$/\r/' <<- EOF
		${version} 405 Method Not Allowed
		Connection: close
		Content-Length: 0
		Allow: GET

		EOF
	fi

	if [[ $version != 'HTTP/1.1' && $version != 'HTTP/1.0' ]]
	then
		printf '%s 400 Bad Request\r\nConnection: close\r\n\r\n' "${version}"
	else
		if [[ "${path}" != '/' && "${path: -1}" == '/' ]]
		then
			# Normalize paths ending with a slash
			path="${path%/}"
		fi

		if [[ -f "${path}" ]]
		then
			content_type=$(file -b --mime-type "${path}")

			# Default to UTF-8 for text files
			# Alternative: use `file -bi`
			grep -E '^text\/.+' <<< "${content_type}" >/dev/null
			if [[ $? -eq 0 && ! $content_type =~ ';' ]]
			then
				content_type+=';charset=UTF-8'
			fi

			# Race condition: file size might change between checking the size and reading it's contents
			content_length=$(wc -c "${path}")

			# File content can't be saved in a variable to preserve null bytes
			sed 's/$/\r/' <<- EOF
			${version} 200 OK
			Connection: close
			Content-Length: ${content_length}
			Content-Type: ${content_type}
			Date: $(http_now)
			Server: dirls

			EOF

			cat "${path}"
			return
		elif [[ -d "${path}" ]]
		then
			http_status='200 OK'

			read -r -d '' body \
				< <(format_listing_html "${path}" | html_template "$(html_escape <<< "dirls - ${path}")")

			content_type="text/html"
		else
			local html
			http_status='404 Not Found'
			content_type='text/html'
			read -r -d '' html <<- EOF
			<h1>Not Found</h1>
			EOF
			body=$(html_template 'dirls - Not Found' <<< "${html}")
		fi

		# ${#body} returns Unicode codepoint length, which may be different from byte length
		content_length=$(wc -c <<< "${body}")

		sed 's/$/\r/' <<- EOF
		${version} ${http_status}
		Connection: close
		Content-Type: ${content_type}
		Content-Length: ${content_length}
		Date: $(http_now)
		Server: dirls

		EOF
		
		# Content should not have LF replaced with CR LF
		printf "%s" "${body}"
	fi
}

function http_serve {
	while true
	do
		# Linux specific:
		# redirect stdout back to stdin, see https://unix.stackexchange.com/a/296434
		: | { nc -l "${DIRLS_PORT:-8080}" | http_handle_request; } > /dev/fd/0
	done
}

function opt_arg_expected {
	echo "option '$1' requires an argument" >&2
	exit 2
}

read -r -d '' help_text << EOF
Usage: $0 [OPTION]... [DIRECTORY]...
       $0 --serve [OPTION]...
Print an HTML directory listing.

  -c, --config <arg>        load config files from <arg>
  -d, --detailed <arg>      include additional file metadata in the listing
  -o, --output <arg>        output to <arg> rather than to stdout
                             (ignored with --serve)
      --sort none|asc|desc  sort the listing
                             none - (default) find.1 order
                             asc  - ascending order
                             desc - descending (reverse) order
  -h, --help                display this help and exit

 HTTP specific options:
      --serve               start an HTTP directory listing server
  -p, --port <arg>          listen on <arg>
EOF

positional_args=()

while (( $# > 0 ))
do
	shift_by=0

	case "$1" in
		-h|--help)
			opt_help=true
			;;
		-c|--config)
			shift_by=1
			if (( $# < 2 ))
			then
				opt_arg_expected "$1"
			fi

			opt_config="$2"
			;;
		-d|--detailed)
			DIRLS_DETAILED=true
			;;
		-o|--output)
			shift_by=1
			if (( $# < 2 ))
			then
				opt_arg_expected "$1"
			fi

			opt_output="$2"
			;;
		--sort)
			shift_by=1
			if (( $# < 2 ))
			then
				opt_arg_expected "$1"
			fi

			case "$2" in
				none)
					DIRLS_SORT=''
					;;
				asc|desc)
					DIRLS_SORT="${2}"
					;;
				*)
					echo "invalid sort order '${2}'" >&2
					exit 2
					;;
			esac
			;;
		--serve)
			opt_serve=true
			;;
		-p|--port)
			shift_by=1
			if (( $# < 2 ))
			then
				opt_arg_expected "$1"
			fi

			opt_port="$2"
			;;
		--)
			shift
			break
			;;
		-*|--*)
			echo "unknown option '$1'" >&2
			exit 2
			;;
		*)
			positional_args+=("$1")
			;;
	esac

	shift $(( shift_by + 1 ))
done

# `--` leaves remaining positional arguments, collect them:
while (( $# > 0 ))
do
	positional_args+=("$1")
	shift
done

if [[ "${opt_help}" == true ]]
then
	echo "${help_text}"
	exit
fi

if [[ "${opt_output}" != "" ]]
then
	exec 1> "${opt_output}"
fi

config_path=${XDG_CONFIG_HOME:-$HOME/.config}/dirls

if [[ "${opt_config}" != "" ]]
then
	config_path="${opt_config}"
fi

mkdir -p "${config_path}"

if [[ ! -f "${config_path}/categories" ]]
then
	cat > "${config_path}/categories" <<- EOF
	Documents=name:.*\.(txt|md|pdf|rtf|odp|doc|docx|html)$
	Images=mime:^image\/.+
	Music=mime:^audio\/.+
	Video=mime:^video\/.+
	EOF
fi

if [[ ! -f "${config_path}/style.css" ]]
then
	cat > "${config_path}/style.css" << EOF
:root {
	box-sizing: border-box;

	font-family: sans-serif;
}

html, body {
	min-height: 100vh;
	margin: 0;
}

html {
	padding: 0;
}

body {
	padding: 1rem;
}
EOF
fi

declare -A category_regexes
# Store keys to keep insertion order
categories=()
while IFS=\= read -r category regex
do
	categories+=("${category}")
	category_regexes["${category}"]="${regex}"
done < "${config_path}/categories"

# webroot=$(realpath ".")

read -r -d '' STYLE < "${config_path}/style.css"

if [[ "${opt_serve}" == true ]]
then
	if [[ opt_port != '' ]]
	then
		DIRLS_PORT="${opt_port}"
	fi
	DIRLS_PORT="${DIRLS_PORT:-8080}"

	URI_PREFIX=''

	if (( ${#positional_args} > 0 ))
	then
		echo "unexpected arguments '${positional_args[@]}'" >&2
		exit 2
	fi

	echo "listening on port '${DIRLS_PORT}'" >&2
	http_serve
else
	URI_PREFIX='file://'

	if [[ "${#positional_args[@]}" == 1 ]]
	then
		title="dirls - ${positional_args[0]}"
	elif [[ "${#positional_args[@]}" == 0 ]]
	then
		positional_args+=('.')
	else
		title="dirls"
	fi

	{
		for i in "${positional_args[@]}"
		do
			format_listing_html "$(realpath -- "${i}")"
		done
	} | html_template "${title}"
fi
