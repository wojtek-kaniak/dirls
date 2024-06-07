#! /usr/bin/env bash

function echo {
	printf "%s\n" "$@"
}

config_path=${XDG_CONFIG_HOME:-$HOME/.config}/dirls

# TODO: write a default config if not present

declare -A category_regexes
while IFS=\= read -r category regex
do
	category_regexes["${category}"]="${regex}"
done < "${config_path}/categories"

webroot=$(realpath ".")
URI_PREFIX="file://"

function uri_encode_path {
	# TODO
	printf "${URI_PREFIX}"
	cat -
}

function html_escape {
	sed 's/\&/\&amp;/g' | sed 's/</\&lt;/g' | sed 's/>/\&gt;/g' \
		| sed 's/"/\&qout;/g' | sed 's/'\''/\&#39/g' # " and ' need to be escaped in attributes
}

STYLE="
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
"

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

# $1 - web root
function format_listing_html {
	local webroot dir_max_depth

	webroot="${1}"

	# TODO: omit empty categories
	# TODO: handle paths containing newlines?
	dir_max_depth=2

	printf "<h2>%s</h2>\n" ${webroot}
	echo "<ul>"
	find "${webroot}" -mindepth 1 -maxdepth ${dir_max_depth} -type d -printf '%P\n' \
		| while read -r path
	do
		printf "<li><a href=\"%s\">%s</a></li>\n" \
			$(uri_encode_path <<< "${webroot}/${path}" | html_escape) \
			$(html_escape <<< "${path}")
	done
	echo "</ul>"

	all_files="$(find "${webroot}" -mindepth 1 -maxdepth 1 -not -type d -printf '%P\n')"
	files_categorized=()

	for category in "${!category_regexes[@]}"
	do
		regex="${category_regexes["${category}"]}"

		printf "<h3>%s:</h3>\n" $(printf "%s" "${category}" | html_escape)
		echo "<ul>"

		while read -r path
		do
			files_categorized+=("${path}")

			printf "<li><a href=\"%s\">%s</a></li>\n" \
				$(uri_encode_path <<< "${webroot}/${path}" | html_escape) \
				$(html_escape <<< "${path}")

		# Avoid creating a subshell with process substitution
		done < <(grep -P ${regex} <<< "${all_files}")

		echo "</ul>"
	done

	echo "<h3>Other:</h3>"
	echo "<ul>"
	while read -r path
	do
		for i in "${files_categorized[@]}"
		do
			if [[ ${i} == ${path} ]]
			then
				continue 2
			fi
		done

		printf "<li><a href=\"%s\">%s</a></li>\n" \
			$(uri_encode_path <<< "${webroot}/${path}" | html_escape) \
			$(html_escape <<< "${path}")
	done <<< "${all_files}"

	echo "</ul>"
}

# format_listing_html $(basename .) | html_template "$(html_escape <<< "dirls - ${webroot}")"

function http_handle_request {
	#local method path version html content_type content_length
	read -r method path version < <(head -n 1 | tr -d '\r' | tr -s ' ')

	# builtin echo $method $path $version

	if [[ $version != 'HTTP/1.1' && $version != 'HTTP/1.0' ]]
	then
		printf '%s 400 Bad Request\r\nConnection: close\r\n\r\n' "${version}"
	else
		# TODO: handle files, 404s etc
		# webroot="${path}"
		URI_PREFIX=''
		read -r -d '' html \
			< <(format_listing_html "${path}" | html_template "$(html_escape <<< "dirls - ${webroot}")")

		content_type="text/html"
		content_length="${#html}"

		sed 's/$/\r/' <<- EOF
		${version} 200 OK
		Connection: abort
		Content-Type: ${content_type}
		Content-Length: ${content_length}
		Date: $(date -uR | sed 's/+0000/GMT/')
		Server: dirls

		EOF
		
		# Content should not have LF replaced with CR LF
		printf "%s" "${html}"
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
