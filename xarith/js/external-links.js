document.addEventListener("DOMContentLoaded", function () {
  document.querySelectorAll("a[href]").forEach(function (link) {
    var href = link.getAttribute("href") || "";
    var isExternal = link.hostname && link.hostname !== location.hostname;
    var isDoxygen = href.match(/\/doxygen[^/]*\//);
    if (isExternal || isDoxygen) {
      link.setAttribute("target", "_blank");
      link.setAttribute("rel", "noopener noreferrer");
    }
  });
});
