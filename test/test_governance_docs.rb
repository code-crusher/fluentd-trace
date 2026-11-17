require_relative 'helper'

class GovernanceDocsTest < Test::Unit::TestCase
  ROOT_DIR = File.expand_path('..', __dir__)

  def read_doc(name)
    File.read(File.join(ROOT_DIR, name), encoding: 'UTF-8')
  end

  # Returns the body of the section whose heading is exactly +heading+,
  # up to the next heading of the same or higher level.
  def section_body(doc, heading)
    lines = doc.lines
    start = lines.index { |line| line.strip == heading }
    return nil unless start

    level = lines[start][/\A#+/].length
    rest = lines[(start + 1)..]
    finish = rest.index { |line| line =~ /\A#+\s/ && line[/\A#+/].length <= level } || rest.length
    rest[0...finish].join
  end

  # Returns the body of the top-level "# Fluentd Maintainers" section,
  # which ends at the first second-level heading.
  def active_maintainers_body(doc)
    lines = doc.lines
    start = lines.index { |line| line.strip == '# Fluentd Maintainers' }
    return nil unless start

    rest = lines[(start + 1)..]
    finish = rest.index { |line| line.start_with?('## ') } || rest.length
    rest[0...finish].join
  end

  def github_handles(section)
    section.scan(%r{https://github\.com/([A-Za-z0-9-]+)}).flatten
  end

  sub_test_case 'GOVERNANCE.md' do
    setup do
      @governance = read_doc('GOVERNANCE.md')
    end

    test 'defines the emeritus maintainer status' do
      body = section_body(@governance, '### Emeritus Maintainers')
      assert_not_nil(body, 'GOVERNANCE.md should have an "Emeritus Maintainers" section')
      assert_match(/5 years/, body)
      assert_match(/resigned/, body)
    end

    test 'emeritus maintainers have no ballot to vote' do
      body = section_body(@governance, '### Emeritus Maintainers')
      assert_match(/do not have a ballot to vote/, body)
    end

    test 'voting section refers to the emeritus status' do
      body = section_body(@governance, '## Voting')
      assert_match(/emeritus/, body)
    end
  end

  sub_test_case 'MAINTAINERS.md' do
    setup do
      @maintainers = read_doc('MAINTAINERS.md')
    end

    test 'lists emeritus maintainers in their own section' do
      body = section_body(@maintainers, '## Emeritus Maintainers')
      assert_not_nil(body, 'MAINTAINERS.md should have an "Emeritus Maintainers" section')
      assert_operator(github_handles(body).length, :>, 0)
    end

    test 'keeps active and emeritus maintainers disjoint' do
      active = active_maintainers_body(@maintainers)
      emeritus = section_body(@maintainers, '## Emeritus Maintainers')
      assert_not_nil(active)
      assert_not_nil(emeritus, 'MAINTAINERS.md should have an "Emeritus Maintainers" section')
      assert_equal([], github_handles(active) & github_handles(emeritus))
    end

    test 'links every maintainer to a GitHub account' do
      active = active_maintainers_body(@maintainers)
      assert_not_nil(active)
      entries = active.lines.grep(/\A-\s/)
      assert_operator(entries.length, :>, 0)
      entries.each do |entry|
        assert_match(%r{\A-\s\[.+\]\(https://github\.com/[A-Za-z0-9-]+\)}, entry)
      end
    end
  end
end
