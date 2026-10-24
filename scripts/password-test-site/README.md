# Password test site

Pages for checking saving and autofill by hand. Serve them on two origins:

    cd scripts/password-test-site && python3 -m http.server 8765 --bind 127.0.0.1

- `login.html`: one-page sign-in. Sign in, save, then focus the email field: the saved login is offered.
- `step1.html` → `step2.html`: two-step sign-in. The username from step one is saved with the password.
- `change.html`: change password. Offers to update the one saved login.
- `signup.html`: create account. Focus the password field: a strong password is offered, filled into both fields and saved.
- `rules.html`: strict `passwordrules`, lengths and `pattern`. The strong password offered fits them.
- `hidden.html`: hidden trap fields. Autofill fills only the visible ones.
- Open the same pages at `http://localhost:8765/`: a different origin, so nothing saved for `127.0.0.1:8765` is offered.

Use made-up passwords only.
