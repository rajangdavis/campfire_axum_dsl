import os
# Active Storage variants made with libvips (image_variant, models/variant.axum.rb): the rows Rails writes (the variant
# record, the variant blob with its byte size and checksum, the `image` attachment) and, with bodies=True, the variant
# bytes a GET answers. Run against the port's image (CANDIDATE_DOCKER=1), whose libvips is the reference's.
HERE = os.path.dirname(os.path.abspath(__file__))
F = lambda name: ("file", os.path.join(HERE, name))
D = "david@37signals.com"
TALK = 486777696
BENDER_KEY = "394959859-BenderBot123"
ACCOUNT = "/account.873240054"
DAVID_AVATAR = "/users/eyJfcmFpbHMiOnsiZGF0YSI6MTI3MzI2MTQxLCJwdXIiOiJ1c2VyL2F2YXRhciJ9fQ--0ac8233a4786ee6c413408416bb81e7107534db5702d351533dc2ecd3876e97f/avatar"
POST = {"Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"}
UUID = [(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", "<uuid>")]

SCENARIOS = [
    # Message#process_attachment: the composer's file post makes the :thumb (resize_to_limit [1200, 800]) in the request.
    *[dict(name=f"thumb/composer/{name}", seed="default", **{"as": D}, settle=4,
           steps=[("POST", f"/rooms/{TALK}/messages", {"message[attachment]": F(name), "message[client_message_id]": f"file-{name}"}, POST)])
      for name in ("photo.jpg", "wide.png", "banner.webp", "avatar.png")],
    # Messages::ByBotsController#create with a multipart file: the same :thumb.
    dict(name="thumb/bot/photo.jpg", seed="default", settle=4, masks=UUID,
         steps=[("POST", f"/rooms/{TALK}/{BENDER_KEY}/messages", ("multipart", {"attachment": F("photo.jpg")}))]),
    # Account#logo_variant: the :large and :small PNGs are made by the first GET of each, and a second GET reads them back.
    dict(name="logo/variants", seed="default", **{"as": D}, settle=4, bodies=True,
         steps=[("PATCH", ACCOUNT, {"account[logo]": F("photo.jpg")}),
                ("GET", "/account/logo?size=small", None), ("GET", "/account/logo", None), ("GET", "/account/logo", None)]),
    # User#avatar_variant: the :square WebP (resize_to_limit [512, 512]) on the first GET of the avatar.
    dict(name="avatar/square", seed="default", **{"as": D}, settle=4, bodies=True,
         steps=[("PATCH", "/users/me/profile", {"user[avatar]": F("wide.png")}), ("GET", DAVID_AVATAR, None), ("GET", DAVID_AVATAR, None)]),
]
