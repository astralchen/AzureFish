# 聊天四语言文案

> 设计文案，不是已接入 App 的 String Catalog。用户昵称、账号、消息正文和媒体名称保持原样。阿拉伯语需后续母语审校。

`{count}`、`{read}`、`{total}` 是整数；`{percent}` 是 locale-aware 百分比，`{size}` 是格式化文件大小，`{duration}` 是录音时长，`{time}` 是本地时间，`{text}` 和 `{name}` 是用户内容。实现时按 String Catalog 配置英文及阿拉伯语复数类别（zero/one/two/few/many/other），本表多数量句是 other 示例，不可直接替代复数规则。动态内容应用双向文本隔离，不翻译、不规范化账号和 URL。

系统相册、权限、分享和文件选择器文案以系统语言行为为准；本表只定义 App 自有入口及恢复说明。日期、数量、时长和文件大小不得拼接本地化句子。

| ID | 简体中文 | 繁體中文 | English | العربية |
| --- | --- | --- | --- | --- |
| chat.copy.001 | 聊天 | 聊天 | Chats | المحادثات |
| chat.copy.002 | 我 | 我 | Me | أنا |
| chat.copy.003 | 发起聊天 | 發起聊天 | New chat | محادثة جديدة |
| chat.copy.004 | 创建群聊 | 建立群組 | Create group | إنشاء مجموعة |
| chat.copy.005 | 群聊详情 | 群組詳細資訊 | Group details | تفاصيل المجموعة |
| chat.copy.006 | 聊天详情 | 聊天詳細資訊 | Chat details | تفاصيل المحادثة |
| chat.copy.007 | 消息 | 訊息 | Message | رسالة |
| chat.copy.008 | 发送 | 傳送 | Send | إرسال |
| chat.copy.009 | 取消 | 取消 | Cancel | إلغاء |
| chat.copy.010 | 完成 | 完成 | Done | تم |
| chat.copy.011 | 返回聊天 | 返回聊天 | Back to chat | العودة إلى المحادثة |
| chat.copy.012 | 重试 | 重試 | Try again | إعادة المحاولة |
| chat.copy.013 | 查找 | 尋找 | Find | بحث |
| chat.copy.014 | 账号 | 帳號 | Account | الحساب |
| chat.copy.015 | 输入对方账号 | 輸入對方帳號 | Enter their account | أدخل حساب الطرف الآخر |
| chat.copy.016 | 用准确账号找到对方 | 使用完整帳號尋找對方 | Find someone by account | ابحث باستخدام الحساب الكامل |
| chat.copy.017 | 只支持准确账号查询，不会搜索你的通讯录。 | 僅支援完整帳號查詢，不會搜尋你的通訊錄。 | Use an exact account. Your contacts are not searched. | استخدم الحساب الكامل. لن يتم البحث في جهات اتصالك. |
| chat.copy.018 | 开始聊天 | 開始聊天 | Start chatting | بدء المحادثة |
| chat.copy.019 | 从一句问候开始 | 從一句問候開始 | Start with a hello | ابدأ بتحية |
| chat.copy.020 | 使用对方的准确账号发起聊天，或邀请几位伙伴建立群聊。 | 使用對方的完整帳號發起聊天，或選擇幾位夥伴建立群組。 | Find someone by their exact account, or select people to create a group. | ابحث عن شخص باستخدام حسابه الكامل، أو اختر أشخاصًا لإنشاء مجموعة. |
| chat.copy.021 | 暂无消息 | 尚無訊息 | No messages yet | لا توجد رسائل بعد |
| chat.copy.022 | 草稿：{text} | 草稿：{text} | Draft: {text} | مسودة: {text} |
| chat.copy.023 | 今天 {time} | 今天 {time} | Today {time} | اليوم {time} |
| chat.copy.024 | {count} 条新消息 | {count} 則新訊息 | {count} new messages | {count} رسائل جديدة |
| chat.copy.025 | 回到最新 | 回到最新 | Jump to latest | الانتقال إلى الأحدث |
| chat.copy.026 | 等待网络 | 等待網路 | Waiting for connection | في انتظار الاتصال |
| chat.copy.027 | 发送中 | 傳送中 | Sending | جارٍ الإرسال |
| chat.copy.028 | 正在确认发送结果 | 正在確認傳送結果 | Confirming send status | جارٍ التحقق من حالة الإرسال |
| chat.copy.029 | 已发送 | 已傳送 | Sent | تم الإرسال |
| chat.copy.030 | 已送达 | 已送達 | Delivered | تم التسليم |
| chat.copy.031 | 已读 | 已讀 | Read | تمت القراءة |
| chat.copy.032 | 发送失败 · 重试 | 傳送失敗 · 重試 | Send failed · Retry | تعذّر الإرسال · أعد المحاولة |
| chat.copy.033 | 重试此消息 | 重試此訊息 | Retry message | إعادة إرسال الرسالة |
| chat.copy.034 | 当前离线，内容已保留 | 目前離線，內容已保留 | Offline. Your content is saved. | أنت غير متصل. تم الاحتفاظ بالمحتوى. |
| chat.copy.035 | 正在同步新消息… | 正在同步新訊息… | Syncing new messages… | جارٍ مزامنة الرسائل الجديدة… |
| chat.copy.036 | 暂时无法同步 · 重试 | 暫時無法同步 · 重試 | Unable to sync · Retry | تعذّرت المزامنة · أعد المحاولة |
| chat.copy.037 | 未找到此账号，请检查后重试。 | 找不到此帳號，請檢查後重試。 | Account not found. Check it and try again. | لم يُعثر على الحساب. تحقّق منه وأعد المحاولة. |
| chat.copy.038 | 这是你自己的账号，请输入对方账号。 | 這是你自己的帳號，請輸入對方帳號。 | This is your account. Enter someone else's account. | هذا حسابك. أدخل حساب شخص آخر. |
| chat.copy.039 | 查询过于频繁，请稍后再试。 | 查詢過於頻繁，請稍後再試。 | Too many searches. Try again later. | عمليات البحث كثيرة. حاول لاحقًا. |
| chat.copy.040 | 网络不可用，输入已保留。 | 網路無法使用，輸入已保留。 | No connection. Your input is saved. | لا يوجد اتصال. تم الاحتفاظ بما أدخلته. |
| chat.copy.041 | 正在确认发送结果，请勿重复发送。 | 正在確認傳送結果，請勿重複傳送。 | Checking whether your message was sent. Please don't send it again. | جارٍ التحقق من إرسال رسالتك. لا ترسلها مرة أخرى. |
| chat.copy.042 | 消息回执 | 訊息回條 | Message receipts | حالات الرسالة |
| chat.copy.043 | {read} / {total} 人已读 | {read} / {total} 人已讀 | Read by {read} of {total} | قرأها {read} من {total} |
| chat.copy.044 | 人数以发送消息时的接收成员为准。 | 人數以傳送訊息時的接收成員為準。 | The total includes recipients when the message was sent. | يشمل الإجمالي المستلمين وقت إرسال الرسالة. |
| chat.copy.045 | 正在更新回执… | 正在更新回條… | Updating receipts… | جارٍ تحديث حالات الرسالة… |
| chat.copy.046 | 复制 | 複製 | Copy | نسخ |
| chat.copy.047 | 本机删除 | 在本機刪除 | Delete on this device | حذف من هذا الجهاز |
| chat.copy.048 | 撤回 | 收回 | Unsend | إلغاء إرسال |
| chat.copy.049 | 此消息已撤回 | 此訊息已收回 | This message was unsent | تم إلغاء إرسال هذه الرسالة |
| chat.copy.050 | 当前版本暂不支持此消息 | 目前版本尚不支援此訊息 | This version can't display this message | لا يدعم هذا الإصدار عرض هذه الرسالة |
| chat.copy.051 | 撤回这条消息？ | 要收回這則訊息嗎？ | Unsend this message? | هل تريد إلغاء إرسال هذه الرسالة؟ |
| chat.copy.052 | 撤回后，所有接收者将看到撤回提示。已保存到其他位置的内容无法收回。 | 收回後，所有接收者會看到收回提示。已儲存至其他位置的內容無法收回。 | Recipients will see an unsent-message notice. Copies saved elsewhere cannot be removed. | سيرى المستلمون إشعارًا بإلغاء الإرسال. لا يمكن إزالة النسخ المحفوظة في أماكن أخرى. |
| chat.copy.053 | 已超过撤回时限 | 已超過收回時限 | The unsend window has expired | انتهت مهلة إلغاء الإرسال |
| chat.copy.054 | 仅删除本机记录？ | 僅刪除此裝置的紀錄嗎？ | Delete only on this device? | هل تريد الحذف من هذا الجهاز فقط؟ |
| chat.copy.055 | 对方和你的其他设备仍可看到此消息。 | 對方和你的其他裝置仍可看到此訊息。 | The recipient and your other devices can still see this message. | سيظل بإمكان المستلم وأجهزتك الأخرى رؤية هذه الرسالة. |
| chat.copy.056 | 清空本机聊天记录 | 清除此裝置的聊天紀錄 | Clear history on this device | مسح السجل من هذا الجهاز |
| chat.copy.057 | 不影响对方和其他设备，不会删除未发送草稿，也不会退出群聊。 | 不影響對方及其他裝置，不會刪除未傳送的草稿，也不會退出群組。 | This won't affect others or your other devices, delete drafts, or leave the group. | لن يؤثر ذلك في الآخرين أو أجهزتك الأخرى، ولن يحذف المسودات أو يغادِر المجموعة. |
| chat.copy.058 | 附件草稿 | 附件草稿 | Attachment draft | مسودة المرفقات |
| chat.copy.059 | 发送前确认 | 傳送前確認 | Review before sending | المراجعة قبل الإرسال |
| chat.copy.060 | 文字与媒体将按下方顺序分别发送。 | 文字與媒體會依下方順序分別傳送。 | Text and media will be sent separately, in this order. | سيتم إرسال النص والوسائط بشكل منفصل بهذا الترتيب. |
| chat.copy.061 | 1 · 文字 | 1 · 文字 | 1 · Text | ١ · نص |
| chat.copy.062 | 2 · 媒体组  /  2 项 · 18.6 MB | 2 · 媒體群組  /  2 項 · 18.6 MB | 2 · Media group / 2 items · 18.6 MB | ٢ · مجموعة وسائط / عنصران · 18.6 MB |
| chat.copy.063 | 调整顺序 | 調整順序 | Reorder | إعادة الترتيب |
| chat.copy.064 | 上移 | 上移 | Move up | نقل إلى الأعلى |
| chat.copy.065 | 下移 | 下移 | Move down | نقل إلى الأسفل |
| chat.copy.066 | 移除 | 移除 | Remove | إزالة |
| chat.copy.067 | 发送 {count} 条消息 | 傳送 {count} 則訊息 | Send {count} messages | إرسال {count} رسائل |
| chat.copy.068 | 正在准备原件 | 正在準備原始檔 | Preparing originals | جارٍ تجهيز الملفات الأصلية |
| chat.copy.069 | 上传中 · {percent} | 上傳中 · {percent} | Uploading · {percent} | جارٍ الرفع · {percent} |
| chat.copy.070 | 上传完成，正在处理 | 上傳完成，正在處理 | Uploaded. Processing… | اكتمل الرفع. جارٍ المعالجة… |
| chat.copy.071 | 附件已就绪，等待发送 | 附件已就緒，等待傳送 | Attachments ready. Waiting to send. | المرفقات جاهزة. في انتظار الإرسال. |
| chat.copy.072 | 上传失败 · 保留内容 | 上傳失敗 · 已保留內容 | Upload failed · Content saved | تعذّر الرفع · تم الاحتفاظ بالمحتوى |
| chat.copy.073 | 上传完成后仍需验证，处理结束前不会发送媒体组。 | 上傳完成後仍需驗證，處理結束前不會傳送媒體群組。 | Uploaded media still needs validation. The group will be sent after processing. | تحتاج الوسائط المرفوعة إلى التحقق. ستُرسل المجموعة بعد انتهاء المعالجة. |
| chat.copy.074 | 重试上传 | 重試上傳 | Retry upload | إعادة الرفع |
| chat.copy.075 | 取消这次发送 | 取消這次傳送 | Cancel this send | إلغاء هذا الإرسال |
| chat.copy.076 | 取消并保留草稿 | 取消並保留草稿 | Cancel and keep draft | الإلغاء والاحتفاظ بالمسودة |
| chat.copy.077 | 已发送的文字不会撤回。尚未提交的媒体保留在草稿中，可稍后重新发送。 | 已傳送的文字不會收回。尚未提交的媒體會保留在草稿中，可稍後重新傳送。 | Sent text stays sent. Unsubmitted media stays in your draft for later. | سيبقى النص المُرسل. ستبقى الوسائط التي لم تُرسل في المسودة لإرسالها لاحقًا. |
| chat.copy.078 | 请先移除超限附件 | 請先移除超出限制的附件 | Remove oversized attachments first | أزِل المرفقات التي تتجاوز الحد أولًا |
| chat.copy.079 | 此视频超过 512 MiB，请移除或选择其他文件。 | 此影片超過 512 MiB，請移除或選擇其他檔案。 | This video exceeds 512 MiB. Remove it or choose another file. | يتجاوز هذا الفيديو 512 MiB. أزِله أو اختر ملفًا آخر. |
| chat.copy.080 | 空间不足，内容已保留。释放空间后可重试。 | 空間不足，內容已保留。釋放空間後可重試。 | Not enough space. Content is saved. Free some space and retry. | المساحة غير كافية. تم الاحتفاظ بالمحتوى. حرّر مساحة وأعد المحاولة. |
| chat.copy.081 | 此附件无法处理，请更换后重试。 | 此附件無法處理，請更換後重試。 | This attachment can't be processed. Replace it and try again. | لا يمكن معالجة هذا المرفق. استبدله وأعد المحاولة. |
| chat.copy.082 | 照片 | 照片 | Photo | صورة |
| chat.copy.083 | 动图 | 動圖 | Animated image | صورة متحركة |
| chat.copy.084 | 视频 | 影片 | Video | فيديو |
| chat.copy.085 | 文件 | 檔案 | File | ملف |
| chat.copy.086 | 打开媒体 | 開啟媒體 | Open media | فتح الوسائط |
| chat.copy.087 | 下载原件 · {size} | 下載原始檔 · {size} | Download original · {size} | تنزيل الملف الأصلي · {size} |
| chat.copy.088 | 下载原件 | 下載原始檔 | Download original | تنزيل الملف الأصلي |
| chat.copy.089 | 取消下载 | 取消下載 | Cancel download | إلغاء التنزيل |
| chat.copy.090 | 完整下载后可分享 | 完整下載後即可分享 | Share after download completes | يمكن المشاركة بعد اكتمال التنزيل |
| chat.copy.091 | 原件已下载并通过完整性检查。 | 原始檔已下載並通過完整性檢查。 | The original is downloaded and verified. | تم تنزيل الملف الأصلي والتحقق من سلامته. |
| chat.copy.092 | 完整性检查失败，文件不可用，请重新下载。 | 完整性檢查失敗，檔案無法使用，請重新下載。 | Verification failed. The file is unavailable. Download it again. | فشل التحقق. الملف غير متاح. نزّله مرة أخرى. |
| chat.copy.093 | 保存到照片 | 儲存到照片 | Save to Photos | حفظ في الصور |
| chat.copy.094 | 保存到文件 | 儲存到檔案 | Save to Files | حفظ في الملفات |
| chat.copy.095 | 分享原件 | 分享原始檔 | Share original | مشاركة الملف الأصلي |
| chat.copy.096 | 已保存到照片 | 已儲存到照片 | Saved to Photos | تم الحفظ في الصور |
| chat.copy.097 | 此消息已撤回，无法继续下载或分享。 | 此訊息已收回，無法繼續下載或分享。 | This message was unsent. Downloading and sharing are unavailable. | تم إلغاء إرسال هذه الرسالة. لم يعد التنزيل أو المشاركة متاحًا. |
| chat.copy.098 | 需要照片添加权限 | 需要加入照片的權限 | Allow adding photos | السماح بإضافة الصور |
| chat.copy.099 | 打开设置 | 開啟設定 | Open Settings | فتح الإعدادات |
| chat.copy.100 | 需要麦克风权限 | 需要麥克風權限 | Microphone access needed | مطلوب الوصول إلى الميكروفون |
| chat.copy.101 | 录制语音 | 錄製語音 | Record voice message | تسجيل رسالة صوتية |
| chat.copy.102 | 录制中 · {duration} | 錄製中 · {duration} | Recording · {duration} | جارٍ التسجيل · {duration} |
| chat.copy.103 | 停止录制 | 停止錄製 | Stop recording | إيقاف التسجيل |
| chat.copy.104 | 试听语音 | 試聽語音 | Preview recording | معاينة التسجيل |
| chat.copy.105 | 重新录制 | 重新錄製 | Record again | التسجيل مجددًا |
| chat.copy.106 | 发送语音 | 傳送語音 | Send voice message | إرسال رسالة صوتية |
| chat.copy.107 | 暂停播放 | 暫停播放 | Pause | إيقاف مؤقت |
| chat.copy.108 | 播放 | 播放 | Play | تشغيل |
| chat.copy.109 | 最长可录制 2 分钟。结束后可试听再发送。 | 最長可錄製 2 分鐘。結束後可試聽再傳送。 | Record up to 2 minutes. Listen before sending. | سجّل لمدة تصل إلى دقيقتين. استمع قبل الإرسال. |
| chat.copy.110 | 已达到 2 分钟，录制已停止；确认后再发送。 | 已達到 2 分鐘，錄製已停止；確認後再傳送。 | Recording stopped at 2 minutes. Review it before sending. | توقف التسجيل بعد دقيقتين. راجعه قبل الإرسال. |
| chat.copy.111 | 录音不足 1 秒，请重新录制。 | 錄音未滿 1 秒，請重新錄製。 | Record at least 1 second. Please try again. | سجّل ثانية واحدة على الأقل. حاول مجددًا. |
| chat.copy.112 | 群名称 | 群組名稱 | Group name | اسم المجموعة |
| chat.copy.113 | 输入群名称 | 輸入群組名稱 | Enter a group name | أدخل اسم المجموعة |
| chat.copy.114 | 成员 | 成員 | Member | عضو |
| chat.copy.115 | 群主 | 群組擁有者 | Owner | مالك المجموعة |
| chat.copy.116 | {count} 位成员 | {count} 位成員 | {count} members | {count} أعضاء |
| chat.copy.117 | 你是群主 | 你是群組擁有者 | You own this group | أنت مالك المجموعة |
| chat.copy.118 | 查找并添加成员 | 尋找並新增成員 | Find and add members | البحث عن أعضاء وإضافتهم |
| chat.copy.119 | 修改群名称 | 修改群組名稱 | Edit group name | تعديل اسم المجموعة |
| chat.copy.120 | 添加／移除成员 | 新增／移除成員 | Add or remove members | إضافة أعضاء أو إزالتهم |
| chat.copy.121 | 转让群主 | 轉讓群組擁有權 | Transfer ownership | نقل ملكية المجموعة |
| chat.copy.122 | 解散群聊 | 解散群組 | Dissolve group | حل المجموعة |
| chat.copy.123 | 退出群聊 | 退出群組 | Leave group | مغادرة المجموعة |
| chat.copy.124 | 群成员 | 群組成員 | Group members | أعضاء المجموعة |
| chat.copy.125 | 添加成员 | 新增成員 | Add members | إضافة أعضاء |
| chat.copy.126 | 仅群主可以添加或移除成员。 | 僅群組擁有者可以新增或移除成員。 | Only the owner can add or remove members. | يمكن للمالك فقط إضافة أعضاء أو إزالتهم. |
| chat.copy.127 | 将 {name} 移出群聊？ | 要將 {name} 移出群組嗎？ | Remove {name} from the group? | هل تريد إزالة {name} من المجموعة؟ |
| chat.copy.128 | 移除后，对方不能接收新消息，仍可查看此前有权限的记录。 | 移除後，對方無法接收新訊息，仍可查看先前有權限的紀錄。 | They won't receive new messages, but can still view their authorized history. | لن يتلقى العضو رسائل جديدة، لكنه سيظل قادرًا على عرض السجل المصرّح له به. |
| chat.copy.129 | 选择新的群主 | 選擇新的群組擁有者 | Choose a new owner | اختيار مالك جديد |
| chat.copy.130 | 确认转让 | 確認轉讓 | Confirm transfer | تأكيد نقل الملكية |
| chat.copy.131 | 转让完成后，你将成为普通成员。 | 轉讓完成後，你會成為一般成員。 | After the transfer, you'll become a regular member. | بعد نقل الملكية، ستصبح عضوًا عاديًا. |
| chat.copy.132 | 请先转让群主 | 請先轉讓群組擁有權 | Transfer ownership first | انقل الملكية أولًا |
| chat.copy.133 | 你已退出此群，可查看此前记录 | 你已退出此群組，可查看先前紀錄 | You left this group. Previous history is available. | غادرت هذه المجموعة. لا يزال السجل السابق متاحًا. |
| chat.copy.134 | 你已被移出此群，可查看此前记录。 | 你已被移出此群組，可查看先前紀錄。 | You were removed. Previous history is available. | تمت إزالتك من المجموعة. لا يزال السجل السابق متاحًا. |
| chat.copy.135 | 群聊已解散，可查看此前记录 | 群組已解散，可查看先前紀錄 | This group was dissolved. Previous history is available. | تم حل المجموعة. لا يزال السجل السابق متاحًا. |
| chat.copy.136 | 离开期间的消息不可查看 | 離開期間的訊息無法查看 | Messages sent while you were away aren't available. | الرسائل المرسلة أثناء غيابك غير متاحة. |
| chat.copy.137 | 群资料已更新。你的输入已保留，请查看最新资料后再保存。 | 群組資料已更新。你的輸入已保留，請查看最新資料後再儲存。 | Group details changed. Your input is saved. Review the latest details before saving. | تغيّرت تفاصيل المجموعة. تم الاحتفاظ بإدخالك. راجع أحدث التفاصيل قبل الحفظ. |
| chat.copy.138 | 你已退出此群，无法发送消息 | 你已退出此群組，無法傳送訊息 | You left this group and can't send messages. | غادرت هذه المجموعة ولا يمكنك إرسال الرسائل. |
| chat.copy.139 | 保留的草稿 | 保留的草稿 | Saved draft | المسودة المحفوظة |
| chat.copy.140 | 查看保留的草稿 | 查看保留的草稿 | View saved draft | عرض المسودة المحفوظة |
| chat.copy.141 | 当前无法向此会话发送，草稿仍保留在本机。 | 目前無法向此聊天傳送，草稿仍保留在本機。 | You can't send here now. Your draft is saved on this device. | لا يمكنك الإرسال هنا الآن. تم الاحتفاظ بمسودتك على هذا الجهاز. |
| chat.copy.142 | 复制文字 | 複製文字 | Copy text | نسخ النص |
| chat.copy.143 | 删除草稿 | 刪除草稿 | Delete draft | حذف المسودة |
| chat.copy.144 | 文字已复制 | 文字已複製 | Text copied | تم نسخ النص |
| chat.copy.145 | 删除这份草稿？ | 要刪除這份草稿嗎？ | Delete this draft? | هل تريد حذف هذه المسودة؟ |
| chat.copy.146 | 会删除本机未发送的文字与附件，不影响已发送消息。 | 會刪除此裝置未傳送的文字與附件，不影響已傳送訊息。 | Unsent text and attachments will be deleted on this device. Sent messages aren't affected. | سيُحذف النص والمرفقات غير المرسلة من هذا الجهاز. لن تتأثر الرسائل المرسلة. |
| chat.copy.147 | 继续播放 | 繼續播放 | Resume playback | متابعة التشغيل |
| chat.copy.148 | 成员已移除 | 成員已移除 | Member removed | تمت إزالة العضو |
