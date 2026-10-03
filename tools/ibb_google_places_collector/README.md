# Ibb Google Places Collector

أداة لجمع بيانات الأنشطة التجارية في نطاق مدينة إب باستخدام Google Places API (New) الرسمي، عبر شبكة جغرافية متعددة الخلايا واستعلامات قطاعية متعددة مع pagination وإزالة التكرار بواسطة Place ID.

هذه الأداة ليست scraper لواجهة Google Maps HTML، ولا تتجاوز CAPTCHA أو جلسات المتصفح أو حدود الخدمة.

Text Search (New) يعرض حتى 20 نتيجة في الصفحة وبحد أقصى 60 نتيجة عبر الصفحات لكل استعلام، لذلك لا توجد طريقة صادقة لضمان كل منشأة من استعلام واحد. الأداة تعالج ذلك بشبكة مكانية + استعلامات قطاعية + deduplication.

مراجع Google الرسمية:
https://developers.google.com/maps/documentation/places/web-service/overview
https://developers.google.com/maps/documentation/places/web-service/text-search
https://developers.google.com/maps/documentation/places/web-service/nearby-search
https://developers.google.com/maps/documentation/places/web-service/place-details
https://developers.google.com/maps/documentation/places/web-service/place-photos
https://cloud.google.com/maps-platform/terms/maps-service-terms

## إعداد إب
ibb_city_box.json يحتوي صندوق دراسة تقريبي حول مدينة إب وليس حدودًا إدارية رسمية:
13.92 <= latitude <= 14.03
44.12 <= longitude <= 44.25

## تشغيل محلي
pip install -r requirements.txt
export GOOGLE_MAPS_API_KEY=YOUR_KEY
python collector.py --config ibb_city_box.json --dry-run
python collector.py --config ibb_city_box.json --output-dir output

النتائج تذهب إلى output/ وهو مستثنى من Git.

## الحقول
Place ID، اسم النشاط، العنوان، الهاتف الوطني والدولي، الموقع، الإحداثيات، النوع الأساسي، الأنواع، حالة النشاط، ساعات العمل، رابط Google Maps، ومؤشر وجود صور.

## التفاصيل والصور
اجعل fetch_details=true عند الحاجة إلى Place Details. الصور غير مفعّلة افتراضيًا. Place Photos متاح رسميًا، لكن موارد الصور وأسماء الموارد لها قيود استخدام وتخزين؛ لا تحفظ صور Google أو مواردها في GitHub العام دون مراجعة اتفاقك وسياسات Google.

## GitHub Actions
أضف Secret باسم GOOGLE_MAPS_API_KEY ثم شغّل workflow يدويًا من Actions. الـworkflow لا يلتزم النتائج إلى branch تلقائيًا.

## تنبيه قانوني/تشغيلي
لا تستخدم هذا المشروع لكشط واجهة Google Maps أو لتجاوز وسائل الحماية. قبل نشر النتائج أو تخزينها على GitHub، راجع Terms وقيود caching/exporting الخاصة بحساب Google Maps Platform المستخدم.