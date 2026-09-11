# The repository's docs/CHANGELOG.md, split into releases for the "What's new"
# page.
#
# The stock page fetched the latest GitHub release of maybe-finance/maybe, which
# says nothing about a fork. Reading the file that ships with the deployed code
# means the page always describes exactly what is running, and needs no network.
#
# Sections are the file's `## ` headings (Keep a Changelog style). Everything
# up to the first `## ` is the preamble and is not shown.
class Changelog
  PATH = Rails.root.join("docs/CHANGELOG.md")

  Release = Data.define(:title_html, :version, :date, :body_html)

  class << self
    # An unreadable file yields no releases rather than an error page: the
    # changelog is the least important thing on the screen it is shown on.
    def releases(path: PATH)
      sections(File.read(path)).map { |heading, body| build_release(heading, body) }
    rescue Errno::ENOENT, Errno::EACCES
      []
    end

    private
      def sections(text)
        parts = text.split(/^## +/m).drop(1)
        parts.map do |part|
          heading, body = part.split("\n", 2)
          [ heading.to_s.strip, body.to_s.strip ]
        end
      end

      def build_release(heading, body)
        Release.new(
          title_html: inline_html(heading),
          version: heading[/\[([^\]]+)\]/, 1] || heading,
          date: heading.scan(/\d{4}-\d{2}-\d{2}/).last&.then { |d| Date.parse(d) rescue nil },
          body_html: renderer.render(body)
        )
      end

      # A heading rendered as markdown comes back as one paragraph; unwrap it so
      # it can sit inside the page's own <h2>.
      def inline_html(text)
        renderer.render(text).strip.delete_prefix("<p>").delete_suffix("</p>")
      end

      # No hard_wrap: the file is wrapped at 80 columns, and turning every line
      # break into <br> would shred the paragraphs.
      def renderer
        @renderer ||= Redcarpet::Markdown.new(
          Redcarpet::Render::HTML.new(link_attributes: { target: "_blank", rel: "noopener noreferrer" }),
          autolink: true, tables: true, fenced_code_blocks: true, strikethrough: true
        )
      end
  end
end
