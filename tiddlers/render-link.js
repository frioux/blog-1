/*\
title: $:/render-link.js
type: application/javascript
module-type: macro

\*/

(function() {
    exports.name = 'tv-get-export-link';
    exports.params = [{ name: 'to' }];
    exports.run = function(to) {
        let tiddler = $tw.wiki.getTiddler(to);

        if(tiddler && tiddler.getFieldString('relative_url') != '') {
            return tiddler.getFieldString('relative_url');
        }

        let prefix = '';
        // XXX remove this `tiddler &&` check
        if(tiddler && tiddler.hasTag('Blog Post')) {
            prefix = 'blog/';
        }

        return prefix + to.toLowerCase().replace(/\W+/g, '-').replace(/-+$/, '');
    };
})();
