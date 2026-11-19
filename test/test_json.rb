require_relative 'helper'
require 'fluent/json'
require 'json'

class JSONResumableParserFactoryTest < Test::Unit::TestCase
  setup do
    @options = Fluent::DEFAULT_JSON_PARSE_OPTIONS
  end

  test 'returns a parser with the ResumableParser interface' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    parser << '{"a":1}{"b":2}'
    assert parser.parse
    assert_equal({'a' => 1}, parser.value)
    assert parser.parse
    assert_equal({'b' => 2}, parser.value)
    assert_false parser.parse
    assert parser.empty?
  end

  test 'returns the native parser when it is available, the pure Ruby one otherwise' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)
    if defined?(JSON::ResumableParser)
      assert_kind_of JSON::ResumableParser, parser
    else
      assert_kind_of Fluent::JSONResumableParserFactory::PureResumableParser, parser
    end
  end

  data('mid-token'   => ['{"a":1}{"b":2', [{"a" => 1}], false],
       'after-colon' => ['{"a":1}{"b":',  [{"a" => 1}], false],
       'after-brace' => ['{"a":1}{',      [{"a" => 1}], false],
       'after-comma' => ['{"a":1,',       [],           false],
       'complete'    => ['{"a":1}{"b":2}', [{"a" => 1}, {"b" => 2}], true])
  def test_incremental_feeding(data)
    input, expected_records, clean_end = data
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    records = []
    parser << input
    while parser.parse
      records << parser.value
    end
    assert_equal expected_records, records
    assert_equal clean_end, parser.empty?
  end

  test 'parses documents split across chunks' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    '{"a":"\u00'.each_char { |c| parser << c }
    assert_false parser.parse
    '41"}'.each_char { |c| parser << c }
    assert parser.parse
    assert_equal({'a' => 'A'}, parser.value)
    assert parser.empty?
  end

  test 'raises JSON::ParserError on malformed input and keeps it for the next parse' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    parser << '{"a":1}{,}{"b":2}'
    assert parser.parse
    assert_equal({'a' => 1}, parser.value)
    assert_raise(JSON::ParserError) do
      parser.parse
    end
    # Like the native parser, the malformed document stays in the buffer and the
    # error recurs until the caller resets the parser.
    assert_raise(JSON::ParserError) do
      parser.parse
    end
    assert_false parser.empty?
  end

  test 'parses a stream of scalars' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    records = []
    parser << '12 34.5 true null "s"'
    while parser.parse
      records << parser.value
    end
    assert_equal([12, 34.5, true, nil, 's'], records)
    assert parser.empty?
  end

  test 'parses documents with trailing whitespace and comments' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    records = []
    parser << '{"a":1} /* comment */ {"b":2}' "\n\t "
    while parser.parse
      records << parser.value
    end
    assert_equal([{'a' => 1}, {'b' => 2}], records)
    assert parser.empty?
  end

  data('block comment before the first document' => ['/* comment */ {"a":1}', [{'a' => 1}]],
       'line comment before the first document'  => ["// comment\n{\"a\":1}", [{'a' => 1}]],
       'line comment between documents'          => ["{\"a\":1}\n// comment\n{\"b\":2}", [{'a' => 1}, {'b' => 2}]],
       'comment inside a document'               => ['{"a":1 /* comment */}', [{'a' => 1}]],
       'comment between a key and its value'     => ['{"a" /* comment */: 1}', [{'a' => 1}]],
       'comment around a scalar document'        => ['/* c */ 12 ', [12]])
  def test_parses_comments_between_documents(data)
    input, expected = data
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    records = []
    parser << input
    while parser.parse
      records << parser.value
    end
    assert_equal expected, records
    assert parser.empty?
  end

  data('comments and scalars' => ['12 /* x */ true "s" ', [12, true, 's']],
       'comments and objects' => ['/* c */ {"a":1} {"b" /* c */:2}', [{'a' => 1}, {'b' => 2}]],
       'comments and arrays'  => ['[1 /* c */, 2] {"a":1}', [[1, 2], {'a' => 1}]])
  def test_parses_scalars_around_comments(data)
    input, expected = data
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    records = []
    parser << input
    while parser.parse
      records << parser.value
    end
    assert_equal expected, records
    assert parser.empty?
  end

  test 'parses a string document' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    records = []
    parser << '"x" {"a":1} 12 '
    while parser.parse
      records << parser.value
    end
    assert_equal(['x', {'a' => 1}, 12], records)
    assert parser.empty?
  end

  test 'parses documents fed byte by byte' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    records = []
    '{"a":1} /* c */ {"b":2}'.each_char { |c| parser << c }
    while parser.parse
      records << parser.value
    end
    assert_equal([{'a' => 1}, {'b' => 2}], records)
    assert parser.empty?
  end

  test 'keeps an unterminated comment open' do
    parser = Fluent::JSONResumableParserFactory.parser(@options)

    parser << '{"a":1} /* comment'
    assert parser.parse
    assert_equal({'a' => 1}, parser.value)
    assert_false parser.empty?
    ' */ {"b":2}'.each_char { |c| parser << c }
    assert parser.parse
    assert_equal({'b' => 2}, parser.value)
    assert parser.empty?
  end
end
