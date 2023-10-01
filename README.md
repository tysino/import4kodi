# import4kodi
Imports movie or series into folder structure readable by the [Kodi](kodi.tv) library scanner, by creating hardlinks.
Rename `import4kodi.conf.example` to `import4kodi.conf` and edit it for your needs (set torrent directory etc.).

I don't know why I created this as a bash script, but it was a fun way of learning the language.
Since it was more work than expected I thought I'd share it. Have fun.

To get a list of completed torrents from the [transmission](transmissionbt.com) webGUI, use following JS:
`var x=[];$($($("#inspector_file_list").children()[0]).children()[0]).children("div").each(function(a,b) { var y=$($(b).children("li.complete")[0]).children(".inspector_torrent_file_list_entry_name"); if (y.length > 0) { x.push(y[0].innerHTML)}}); console.log('"'+x.join('" "')+'"')`
Then to import/check them:
`for t in <above movie list>; do ./import4kodi.sh /usr/torrent/movie/"$t"; done`

## TODO
- [ ] parted files
- [ ] unrar subs
- [ ] look in Subs folder
