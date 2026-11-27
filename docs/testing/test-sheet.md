# JIBIJI test sheet

Write these once on the iPad, on three new pages, with your normal handwriting. Every word has a known answer, so after
the pages are pulled off the iPad the local tests score them (`WrittenTestSheetTests` in `JIBIJITests/TestSheetTests.swift`,
which holds the same list with the answers).

- Write each numbered item as its own note, top to bottom. Don't write the numbers.
- Do the odd things on purpose: missing tones, a wrong tone, a gap, a cut-short word. Those are the tests.
- The "How" column says where to put it or what to leave out. If it's blank, write it on one line: Hanzi, Pinyin, meaning.
- About 20–30 minutes in all. No need to tap Suggest or make cards: the tests do that.

## Page 1: fields and tones

| # | Write | How |
| --- | --- | --- |
| 1 | 你好 nǐ hǎo hello | |
| 2 | 谢谢 xiè xie thank you | second syllable has no mark |
| 3 | 好 ⎵⎵⎵ hǎo xiàng | leave a gap after 好; no meaning |
| 4 | 学习 xue xi to study | no tone marks |
| 5 | 朋友 péng you | no meaning |
| 6 | 老师 lǎo shí teacher | the mark on shi is wrong on purpose |
| 7 | 中国 zhōng | stop after zhōng; no meaning |
| 8 | 喜欢 | Hanzi only |
| 9 | māma | Pinyin only |
| 10 | 女 nǚ woman | ü with its dots |
| 11 | 六 liù six | |
| 12 | 知道 zhīdào to know | Pinyin joined, no space |
| 13 | 等于 deng | no mark, second syllable left off |

## Page 2: where things are

| # | Write | How |
| --- | --- | --- |
| 14 | 电脑 diàn nǎo computer | Pinyin **above** the Hanzi, meaning to the right |
| 15 | 苹果 píng guǒ apple | meaning on the line **below** |
| 16 | 咖啡 kā fēi coffee | right at the right edge of the screen |
| 17 | 医生 yī shēng doctor | let the line slope upward |
| 18 | 大 dà big | very large |
| 19 | 小 xiǎo small | very small |
| 20 | 猫 māo cat | same line as 21, wide gap between |
| 21 | 狗 gǒu dog | same line as 20 |
| 22 | 茶 chá tea | draw a circle around 茶 |
| 23 | 睡觉 shuì jiào to sleep | draw an arrow pointing at it from the left |

## Page 3: kinds of words

| # | Write | How |
| --- | --- | --- |
| 24 | 虎头蛇尾 hǔ tóu shé wěi | idiom; no meaning |
| 25 | 虽然 suī rán although | |
| 26 | 但是 dàn shì but | |
| 27 | 已经 yǐ jīng already | 已, not 己 |
| 28 | 自己 zì jǐ oneself | 己, not 已 |
| 29 | 认真 rèn zhēn serious | |
| 30 | 伤 shāng injury | |
| 31 | 四 sì four | |
| 32 | 十 shí ten | |
| 33 | 中文 Zhōngwén Chinese | capital Z, joined |
| 34 | 北京 Běi jīng Beijing | capital B |
| 35 | 时间 shí jiān time | |
| 36 | 吃饭 chī fàn to eat | |

## After writing

Tell Claude which pages they are. It pulls them (`scripts/pull-ipad-evidence.sh`) and runs:

```bash
TEST_RUNNER_JIBIJI_SHEET=1 TEST_RUNNER_JIBIJI_PAGES=page-14,page-15,page-16 xcodebuild test-without-building -only-testing:JIBIJITests/WrittenTestSheetTests ...
```

The score goes to `../jibiji-device-evidence-private/ipad/sheet-report.md`.
