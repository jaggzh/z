zcdss() {
	local ssdir=$(z --pssd)
	cd -- "${ssdir%/*}"
}
