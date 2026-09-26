enum Words {
    static let latin: [String] = """
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna \
    aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis \
    aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat \
    non proident sunt culpa qui officia deserunt mollit anim id est laborum curabitur pretium tincidunt lacus \
    gravida orci vestibulum ante primis faucibus luctus ultrices posuere cubilia curae nullam varius turpis \
    quisque semper justo at risus donec venenatis ligula erat ultricies dignissim vivamus vel nibh nunc porta \
    vulputate tellus fusce integer mauris pellentesque habitant morbi tristique senectus netus malesuada fames \
    egestas praesent sapien eleifend aliquam rhoncus phasellus felis sagittis scelerisque suspendisse potenti \
    maecenas lobortis condimentum interdum fermentum nam hendrerit mattis diam accumsan augue etiam vitae
    """.split(separator: " ").map(String.init)

    static let kannada: [String] = [
        "ಕನ್ನಡ", "ಭಾಷೆ", "ಸಾಹಿತ್ಯ", "ಬರಹ", "ಲಿಪಿ", "ಪುಸ್ತಕ", "ಓದು", "ಬರೆ", "ಮನೆ", "ನಗರ", "ಹಳ್ಳಿ", "ಬೆಂಗಳೂರು",
        "ಮೈಸೂರು", "ಕರ್ನಾಟಕ", "ಜನರು", "ಕಥೆ", "ಕವನ", "ಹಾಡು", "ನದಿ", "ಬೆಟ್ಟ", "ಮಳೆ", "ಬಿಸಿಲು", "ಚಳಿ", "ಹೂವು",
        "ಮರ", "ಎಲೆ", "ಹಣ್ಣು", "ಅನ್ನ", "ನೀರು", "ಹಾಲು", "ಕ್ಷೇತ್ರ", "ಜ್ಞಾನ", "ಸ್ತ್ರೀ", "ವಿದ್ಯಾರ್ಥಿ", "ಶಿಕ್ಷಕ",
        "ಪ್ರಶ್ನೆ", "ಉತ್ತರ", "ಸಮಯ", "ದಿನ", "ರಾತ್ರಿ", "ಬೆಳಗ್ಗೆ", "ಸಂಜೆ", "ವರ್ಷ", "ತಿಂಗಳು", "ವಾರ", "ಇಂದು", "ನಾಳೆ",
        "ನಿನ್ನೆ", "ಮತ್ತು", "ಆದರೆ", "ಅಥವಾ", "ಎಂದು", "ಅವರು", "ನಾವು", "ನೀವು", "ಅದು", "ಇದು", "ಯಾವ", "ಎಲ್ಲಿ", "ಹೇಗೆ",
        "ಏಕೆ", "ಸಂಪಾದಕ", "ಪ್ರಬಂಧ", "ಅಧ್ಯಾಯ", "ಪರಿಚ್ಛೇದ", "ಪಟ್ಟಿ", "ಕೋಷ್ಟಕ", "ಚಿತ್ರ", "ಸಂಕೇತ", "ಅಕ್ಷರ", "ಪದ",
        "ವಾಕ್ಯ", "ಅರ್ಥ", "ಸ್ವರ", "ವ್ಯಂಜನ", "ದೃಷ್ಟಿ", "ಸೃಷ್ಟಿ", "ವೃತ್ತ", "ಶ್ರದ್ಧೆ", "ಕ್ರಮ", "ಪ್ರಯತ್ನ",
    ]

    static let devanagari: [String] = [
        "हिन्दी", "भाषा", "साहित्य", "लेखन", "पुस्तक", "पढ़ना", "लिखना", "घर", "नगर", "गाँव", "लोग", "कहानी",
        "कविता", "गीत", "नदी", "पहाड़", "बारिश", "धूप", "सर्दी", "फूल", "पेड़", "पत्ता", "फल", "पानी", "दूध",
        "क्षेत्र", "ज्ञान", "स्त्री", "विद्यार्थी", "शिक्षक", "प्रश्न", "उत्तर", "समय", "दिन", "रात", "सुबह", "शाम",
        "वर्ष", "महीना", "सप्ताह", "आज", "कल", "और", "लेकिन", "या", "कि", "वे", "हम", "आप", "वह", "यह", "क्यों",
        "कैसे", "कहाँ", "संपादक", "निबंध", "अध्याय", "अनुच्छेद", "सूची", "तालिका", "चित्र", "अक्षर", "शब्द", "वाक्य",
        "अर्थ", "स्वर", "व्यंजन", "दृष्टि", "सृष्टि", "वृत्त", "श्रद्धा", "क्रम", "प्रयत्न", "द्वार", "ट्रेन",
    ]

    static let tamil: [String] = ["தமிழ்", "மொழி", "இலக்கியம்", "எழுத்து", "புத்தகம்", "படிக்க", "வீடு", "நகரம்", "மக்கள்", "கதை", "கவிதை", "பாடல்", "ஆறு", "மலை", "மழை", "பூ", "மரம்", "நீர்", "நேரம்", "நாள்", "இன்று", "நாளை", "மற்றும்", "ஆனால்", "க்ஷ", "ஸ்ரீ"]
    static let arabic: [String] = ["العربية", "لغة", "أدب", "كتابة", "كتاب", "قراءة", "بيت", "مدينة", "قرية", "ناس", "قصة", "شعر", "أغنية", "نهر", "جبل", "مطر", "شمس", "زهرة", "شجرة", "ماء", "وقت", "يوم", "ليل", "صباح", "مساء", "سنة", "شهر", "اليوم", "غدا", "و", "لكن", "أو"]
    static let hebrew: [String] = ["עברית", "שפה", "ספרות", "כתיבה", "ספר", "קריאה", "בית", "עיר", "כפר", "אנשים", "סיפור", "שיר", "נהר", "הר", "גשם", "שמש", "פרח", "עץ", "מים", "זמן", "יום", "לילה", "בוקר", "ערב", "שנה", "חודש", "היום", "מחר", "ו", "אבל", "או"]
    static let japanese: [String] = ["日本語", "の", "文章", "を", "書く", "こと", "は", "楽しい", "です", "。", "エディタ", "が", "軽く", "速い", "と", "気持ち", "いい", "、", "段落", "見出し", "表", "コード", "数式", "画像", "リンク", "脚注"]
    static let chinese: [String] = ["中文", "写作", "是", "一种", "乐趣", "。", "编辑器", "应该", "轻快", "而", "可靠", "，", "段落", "标题", "表格", "代码", "公式", "图片", "链接", "脚注", "文档", "字体", "排版", "光标", "选择"]
    static let korean: [String] = ["한국어", "글쓰기", "는", "즐겁다", "편집기", "가", "가볍고", "빠르면", "좋다", "문단", "제목", "표", "코드", "수식", "이미지", "링크", "각주", "문서", "글꼴", "조판", "커서", "선택", "그리고", "하지만"]
    static let emoji: [String] = ["😀", "🎉", "👍🏽", "👨‍👩‍👧‍👦", "🇮🇳", "🧑‍💻", "❤️", "🚀", "🙏🏾", "🏳️‍🌈", "🐍", "☕️"]
}
