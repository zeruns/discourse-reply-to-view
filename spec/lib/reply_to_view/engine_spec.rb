# frozen_string_literal: true

# 块提取引擎单元测试
RSpec.describe ReplyToView::Engine do
  describe ".extract" do
    it "提取块级 reply 块（类型 / 内容 / 序号）" do
      blocks = described_class.extract(<<~MD)
        前文
        [reply-visible]
        SECRET
        [/reply-visible]
        后文
      MD

      expect(blocks.size).to eq(1)
      expect(blocks[0].type).to eq(:reply)
      expect(blocks[0].content).to eq("SECRET")
      expect(blocks[0].index).to eq(1)
      expect(blocks[0].count).to be_nil
    end

    it "提取 [reply-visible=N] 的计数值" do
      blocks = described_class.extract("[reply-visible=5]\nSECRET\n[/reply-visible]\n")
      expect(blocks[0].count).to eq(5)
    end

    it "非法计数值返回 nil（0、负数、非数字）" do
      expect(described_class.extract("[reply-visible=0]\nx\n[/reply-visible]\n")[0].count).to be_nil
      expect(described_class.extract("[reply-visible=-1]\nx\n[/reply-visible]\n")[0].count).to be_nil
      expect(described_class.extract("[reply-visible=abc]\nx\n[/reply-visible]\n")[0].count).to be_nil
    end

    it "多块按出现顺序编号" do
      blocks = described_class.extract(<<~MD)
        [login-visible]
        A
        [/login-visible]
        [reply-visible]
        B
        [/reply-visible]
      MD
      expect(blocks.map(&:type)).to eq(%i[login reply])
      expect(blocks.map(&:index)).to eq([1, 2])
    end

    it "未闭合的标记不产生块" do
      expect(described_class.extract("[reply-visible]\nSECRET\n")).to be_empty
      expect(described_class.extract("前置 [reply-visible]\nSECRET\n[/reply-visible]\n")).to be_empty
    end

    it "内容保留原始缩进" do
      blocks = described_class.extract("[reply-visible]\n  indented\n    deeper\n[/reply-visible]\n")
      expect(blocks[0].content).to eq("  indented\n    deeper")
    end
  end

  describe ".replace_blocks" do
    it "将标记块替换为占位文本，保留其余内容" do
      result = described_class.replace_blocks(<<~MD, "【已隐藏】")
        before
        [reply-visible]
        SECRET
        [/reply-visible]
        after
      MD

      expect(result).to include("before")
      expect(result).to include("【已隐藏】")
      expect(result).to include("after")
      expect(result).not_to include("SECRET")
      expect(result).not_to include("[reply-visible]")
    end
  end

  describe ".strip_marks" do
    it "剥离嵌套标记但保留正文（供注入内容二次渲染前预处理）" do
      result = described_class.strip_marks(<<~MD)
        outer text
        [login-visible]
        inner text
        [/login-visible]
        tail
      MD

      expect(result).to include("outer text")
      expect(result).to include("inner text")
      expect(result).to include("tail")
      expect(result).not_to include("[login-visible]")
    end
  end

  describe ReplyToView::Checksum do
    it "FNV-1a 基准值（与 JS 端实现共同遵守的向量）" do
      # 空串基准：FNV-1a offset basis
      expect(described_class.fnv1a("")).to eq(0x811c9dc5)
      # ASCII 向量
      expect(described_class.fnv1a("a")).to eq(0xe40c292c)
      expect(described_class.fnv1a("foobar")).to eq(0xbf9cf968)
    end

    it "十六进制输出与 JS toString(16) 格式一致（无前导零）" do
      checksum = described_class.fnv1a("foobar")
      expect(described_class.hex("foobar")).to eq(checksum.to_s(16))
    end
  end
end
